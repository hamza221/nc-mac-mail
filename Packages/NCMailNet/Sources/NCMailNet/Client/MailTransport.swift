// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// The seam between `MailClient` and the network.
///
/// Production is `URLSessionTransport`; tests substitute a fake that replays
/// recorded fixtures and can be told to fail, stall or answer 429. Most of the
/// sync engine is testable without a server because of this one protocol.
public protocol MailTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport.
///
/// Cookies are off. `OCS-APIRequest: true` satisfies `passesCSRFCheck()` only
/// while the request carries no session cookie; one stray cookie turns every
/// call into a 412.
public struct URLSessionTransport: MailTransport {
    private let session: URLSession

    public init(session: URLSession = .mail) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MailError.transport(URLError(.badServerResponse))
            }
            return (data, http)
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError.transport(error)
        }
    }
}

extension URLSession {
    /// The one session the app uses.
    ///
    /// Ephemeral, so nothing is written to a shared cookie or credential store.
    /// `waitsForConnectivity` is off because `NWPathMonitor` decides when the
    /// app is offline and pauses the schedulers; a request that waits silently
    /// would hide that. The resource timeout is generous because a `/body` on a
    /// cold IMAP server is genuinely slow.
    public static let mail: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()
}
