// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
import OSLog

/// Login Flow v2, end to end: the browser hand-off, the poll, and a check
/// that the Mail app is actually there before calling it a success.
///
/// [ADR-0002](../../../../docs/decisions/0002-app-password-login-flow-v2.md) is why this
/// exists instead of a password field, and [networking.md](../../../../docs/architecture/networking.md#the-flow)
/// has the four requests in order. An actor because the poll loop is
/// long-running state that only one caller should be driving at a time — a
/// second `start` while a poll is in flight would abandon the first token
/// silently, which an actor's single-threaded access rules out by construction.
public actor LoginFlow {
    /// Where the flow is. A view binds its UI to this rather than reading the
    /// error out of a thrown value, since the "waiting for the browser" and
    /// "polling" states are not errors at all.
    public enum State: Sendable, Equatable {
        case idle
        case awaitingBrowser(URL)
        case polling
        case succeeded(Credentials)
        case failed(LoginError)
    }

    /// Becomes the app password's name in the user's Nextcloud security
    /// settings — see ADR-0002 — so it is sent on every request this flow
    /// makes, not only the first.
    static let userAgent = "Nextcloud Mail (macOS)"

    /// [networking.md](../../../../docs/architecture/networking.md#the-flow): poll every
    /// 2 seconds, give up after 5 minutes.
    static let pollInterval: Duration = .seconds(2)
    static let pollCeiling: TimeInterval = 300

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "auth")

    private let session: URLSession
    private let pollInterval: Duration
    private let pollCeiling: TimeInterval
    private var pollInfo: PollInfo?
    private var isCancelled = false

    public private(set) var state: State = .idle

    public init(session: URLSession = LoginFlow.makeSession()) {
        self.init(session: session, pollInterval: Self.pollInterval, pollCeiling: Self.pollCeiling)
    }

    /// The test seam behind the public initializer. Production always uses
    /// the constants above; tests inject a poll interval measured in
    /// milliseconds and a ceiling measured in fractions of a second, so a
    /// timeout test finishes in the time it takes to run, not in five real
    /// minutes.
    init(session: URLSession, pollInterval: Duration, pollCeiling: TimeInterval) {
        self.session = session
        self.pollInterval = pollInterval
        self.pollCeiling = pollCeiling
    }

    /// A session configured so that a session cookie can never enter it.
    /// ADR-0002: `passesCSRFCheck` only accepts a Basic-authenticated request
    /// with no session cookie, so accepting one here would turn every later
    /// request into a 412.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    /// `POST {server}/index.php/login/v2`. Returns the URL to open in the
    /// system browser; the caller opens it with `NSWorkspace.shared.open`
    /// (`LoginFlow` does not import AppKit — that is a view's job).
    public func start(server: URL) async throws -> URL {
        isCancelled = false
        pollInfo = nil

        let endpoint = server.appendingPathComponent("index.php/login/v2")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, http) = try await send(request)
            guard (200...299).contains(http.statusCode) else {
                Self.logger.debug("login/v2 start: unexpected status \(http.statusCode, privacy: .public)")
                throw LoginError.notNextcloud
            }
            let decoded = try decode(StartResponse.self, from: data)
            pollInfo = PollInfo(token: decoded.poll.token, endpoint: decoded.poll.endpoint)
            state = .awaitingBrowser(decoded.login)
            return decoded.login
        } catch let error as LoginError {
            state = .failed(error)
            throw error
        }
    }

    /// Polls `poll.endpoint` every 2 seconds until the user finishes in the
    /// browser, 5 minutes pass, or `cancel()` is called. A 404 means "still
    /// waiting" — that is the protocol, not a failure.
    ///
    /// On a 200 this also proves the Mail app is installed, by calling the
    /// one route [the brief](../../../../docs/delivery/briefs/WS-01-auth.md) scopes to
    /// WS-01: "account listing beyond proving the credential works" is
    /// explicitly not this workstream's job, but proving it is.
    public func awaitCompletion() async throws -> Credentials {
        // Checked before the `pollInfo` guard below: `cancel()` clears
        // `pollInfo`, and without this ordering a cancel between `start()`
        // and `awaitCompletion()` would be reported as `.notNextcloud`
        // instead of `.cancelled` — caught by this file's own test.
        if isCancelled {
            state = .idle
            throw LoginError.cancelled
        }
        guard let pollInfo else {
            let error = LoginError.notNextcloud
            state = .failed(error)
            throw error
        }

        state = .polling
        let deadline = Date().addingTimeInterval(pollCeiling)

        while true {
            if isCancelled {
                state = .idle
                throw LoginError.cancelled
            }
            if Date() >= deadline {
                let error = LoginError.timedOut
                state = .failed(error)
                throw error
            }

            var request = URLRequest(url: pollInfo.endpoint)
            request.httpMethod = "POST"
            request.httpBody = Data("token=\(pollInfo.token)".utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, http) = try await send(request)
                if http.statusCode == 404 {
                    try await waitBeforeNextPoll()
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    throw LoginError.server(status: http.statusCode)
                }
                let decoded = try decode(PollResponse.self, from: data)
                let credentials = Credentials(
                    server: decoded.server,
                    loginName: decoded.loginName,
                    appPassword: decoded.appPassword
                )
                try await verifyMailApp(credentials)
                state = .succeeded(credentials)
                return credentials
            } catch let error as LoginError {
                state = .failed(error)
                throw error
            }
        }
    }

    /// Stops the poll loop and drops the token. Nothing was ever written to
    /// the Keychain by this actor — that is the caller's job on success —
    /// so a cancel mid-flow has nothing to undo.
    public func cancel() {
        isCancelled = true
        pollInfo = nil
        state = .idle
    }

    // MARK: - Requests

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LoginError.unreachable }
            return (data, http)
        } catch let error as LoginError {
            throw error
        } catch {
            Self.logger.debug("transport failure: \(String(describing: error), privacy: .public)")
            throw LoginError.unreachable
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LoginError.notNextcloud
        }
    }

    private func waitBeforeNextPoll() async throws {
        do {
            try await Task.sleep(for: pollInterval)
        } catch {
            throw LoginError.cancelled
        }
    }

    /// `GET /index.php/apps/mail/api/accounts` with the freshly minted app
    /// password. A 404 here is the one signal that distinguishes "wrong
    /// credentials" from "right credentials, no Mail app" — see
    /// `LoginError.mailAppMissing`.
    private func verifyMailApp(_ credentials: Credentials) async throws {
        let endpoint = credentials.server.appendingPathComponent("index.php/apps/mail/api/accounts")
        var request = URLRequest(url: endpoint)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.basicAuthorization(for: credentials), forHTTPHeaderField: "Authorization")

        let (_, http) = try await send(request)
        if http.statusCode == 404 { throw LoginError.mailAppMissing }
        guard (200...299).contains(http.statusCode) else { throw LoginError.server(status: http.statusCode) }
    }

    private static func basicAuthorization(for credentials: Credentials) -> String {
        let raw = Data("\(credentials.loginName):\(credentials.appPassword)".utf8)
        return "Basic \(raw.base64EncodedString())"
    }

    private struct PollInfo: Sendable {
        let token: String
        let endpoint: URL
    }

    private struct StartResponse: Decodable {
        let login: URL
        let poll: Poll

        struct Poll: Decodable {
            let token: String
            let endpoint: URL
        }
    }

    private struct PollResponse: Decodable {
        let server: URL
        let loginName: String
        let appPassword: String
    }
}
