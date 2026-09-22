// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import OSLog

/// The Nextcloud Mail HTTP client.
///
/// A value type with no mutable state, so an actor can hold one without a
/// warning and two actors can share one without a lock. It writes to the
/// database and never to a view: the invariant in `CLAUDE.md` starts here.
public struct MailClient: Sendable {
    private let server: URL
    private let credentials: any MailCredentials
    private let transport: any MailTransport
    private let retryPolicy: RetryPolicy
    private let userAgent: String

    /// - Parameters:
    ///   - server: the instance root, for example `https://cloud.example.com`.
    ///   - credentials: login name and app password, from WS-01's Keychain.
    ///   - transport: swapped for a fake in tests.
    ///   - retryPolicy: `.standard` retries a read three times at 2 s, 8 s and
    ///     30 s. A mutation is never retried whatever this says.
    public init(
        server: URL,
        credentials: any MailCredentials,
        transport: any MailTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = .standard,
        clientVersion: String = MailClient.defaultVersion
    ) {
        self.server = server
        self.credentials = credentials
        self.transport = transport
        self.retryPolicy = retryPolicy
        userAgent = "Nextcloud Mail (macOS)/\(clientVersion)"
    }

    /// Falls back to a literal when the bundle has no version, which is the
    /// case for a package test target.
    public static let defaultVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    // MARK: - Verbs

    public func get<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T {
        try await perform(endpoint, body: nil as Data?)
    }

    public func post<T: Decodable & Sendable>(
        _ endpoint: Endpoint<T>,
        body: (some Encodable & Sendable)?
    ) async throws -> T {
        try await perform(endpoint, body: body)
    }

    public func post<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T {
        try await perform(endpoint, body: nil as Data?)
    }

    public func put<T: Decodable & Sendable>(
        _ endpoint: Endpoint<T>,
        body: (some Encodable & Sendable)?
    ) async throws -> T {
        try await perform(endpoint, body: body)
    }

    public func put<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T {
        try await perform(endpoint, body: nil as Data?)
    }

    public func delete<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T {
        try await perform(endpoint, body: nil as Data?)
    }

    /// The raw bytes of an endpoint that does not answer JSON: an attachment, an
    /// avatar, or the sanitised HTML fragment.
    public func bytes(_ endpoint: Endpoint<Data>) async throws -> (Data, HTTPURLResponse) {
        try await sendWithRetries(endpoint, bodyData: nil)
    }

    // MARK: - Machinery

    private func perform<T: Decodable & Sendable>(
        _ endpoint: Endpoint<T>,
        body: (some Encodable & Sendable)?
    ) async throws -> T {
        var bodyData: Data?
        if let body {
            do {
                bodyData = try JSONEncoder().encode(body)
            } catch {
                throw MailError.decoding(error, endpoint: endpoint.name)
            }
        }
        let (data, _) = try await sendWithRetries(endpoint, bodyData: bodyData)
        // A 204 or an empty 200 is a success with nothing to read.
        if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            MailLog.net.error(
                "decode failed for \(endpoint.name, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw MailError.decoding(error, endpoint: endpoint.name)
        }
    }

    private func sendWithRetries<T>(
        _ endpoint: Endpoint<T>,
        bodyData: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try buildRequest(endpoint, bodyData: bodyData)
        let attempts = endpoint.isRetryable ? retryPolicy.maximumAttempts : 1
        var lastError: any Error = MailError.transport(URLError(.unknown))

        for attempt in 0..<attempts {
            if attempt > 0 {
                guard let delay = retryDelay(for: lastError, attempt: attempt) else { break }
                try await retryPolicy.sleep(delay)
            }
            do {
                let (data, response) = try await transport.send(request)
                if let error = MailClient.error(for: response, data: data, endpoint: endpoint.name) {
                    guard isRetryable(error) else { throw error }
                    lastError = error
                    MailLog.net.debug(
                        "retrying \(endpoint.name, privacy: .public) after \(response.statusCode, privacy: .public)"
                    )
                    continue
                }
                return (data, response)
            } catch let error as MailError {
                guard isRetryable(error) else { throw error }
                lastError = error
            } catch {
                lastError = MailError.transport(error)
            }
        }
        throw lastError
    }

    private func buildRequest<T>(_ endpoint: Endpoint<T>, bodyData: Data?) throws -> URLRequest {
        var request = URLRequest(url: try endpoint.url(relativeTo: server))
        request.httpMethod = endpoint.method.rawValue
        request.setValue(credentials.basicAuthorizationHeader, forHTTPHeaderField: "Authorization")
        // Load-bearing: passesCSRFCheck() returns true as soon as this header is
        // present, which is what lets an app password work on the /api/ routes.
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Only a read or a sync is retried here, and only for a failure that
    /// another attempt could plausibly fix. A 4xx other than 429 will answer the
    /// same way forever.
    private func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case MailError.transport: true
        case MailError.rateLimited: true
        case MailError.server(let status, _): status >= 500
        default: false
        }
    }

    private func retryDelay(for error: any Error, attempt: Int) -> Duration? {
        // A server that said how long to wait is obeyed exactly; guessing
        // shorter is how a client loses its backfill budget.
        if case MailError.rateLimited(let retryAfter) = error, let retryAfter {
            return retryAfter
        }
        return retryPolicy.delay(beforeAttempt: attempt)
    }

    // MARK: - Status mapping

    /// The failure for a response, or nil when it succeeded.
    static func error(for response: HTTPURLResponse, data: Data, endpoint: String) -> MailError? {
        let failure = MailFailureBody.parse(data)
        switch response.statusCode {
        case 200, 201, 204:
            return nil
        case 202:
            // IncompleteSyncException. The server took the work and is not done.
            return .syncInProgress
        case 400:
            return failure?.isMailboxNotCached == true
                ? .mailboxNotCached
                : .server(status: 400, message: failure?.message)
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 404, 410:
            return .notFound
        case 428:
            return .mailboxNotCached
        case 429, 503:
            return .rateLimited(retryAfter: retryAfter(from: response))
        default:
            return .server(status: response.statusCode, message: failure?.message)
        }
    }

    /// `Retry-After` is either a count of seconds or an HTTP date.
    static func retryAfter(from response: HTTPURLResponse) -> Duration? {
        let raw = response.value(forHTTPHeaderField: "Retry-After")
        guard let header = raw?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Int64(header) {
            return seconds > 0 ? .seconds(seconds) : .zero
        }
        guard let date = httpDateFormatter.date(from: header) else { return nil }
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? .seconds(interval) : .zero
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// Logging for the network layer.
///
/// Nothing here ever interpolates a URL, a header, a mailbox name or a payload.
/// An endpoint name and a status code are the whole vocabulary, which is why
/// they are marked public: everything that could carry mail is simply absent.
enum MailLog {
    static let net = Logger(subsystem: "com.nextcloud.mail", category: "net")
}
