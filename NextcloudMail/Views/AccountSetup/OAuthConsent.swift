// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AuthenticationServices
import Foundation
import OSLog

enum OAuthConsentResult: Equatable {
    case granted
    /// The window was closed, the flow cancelled, or the time limit passed.
    case aborted
}

/// Shows the provider's consent page and reports whether the server ended up holding a token.
@MainActor
protocol OAuthConsenting: AnyObject {
    /// `isConnected` runs the account's connection test; it turns true once the server's
    /// redirect handler has stored the token.
    func obtainConsent(at url: URL, isConnected: @escaping @MainActor () async -> Bool) async -> OAuthConsentResult
}

/// The live consent window ([ADR-0094](../../../docs/decisions/0094-oauth-account-setup-polls-the-connection-test.md)).
///
/// The provider redirects to the *server's* `https` handler, whose page says "You can close
/// this window" — there is no custom-scheme callback an `ASWebAuthenticationSession` could
/// observe. So the session is the window, and completion is the connection test turning
/// true, polled every 2 s for up to 10 min; a granted poll closes the window. The session's
/// own cancel (the user closing it) is "Authorization pop-up closed". When the session cannot
/// start at all, the default browser opens the URL and the same poll runs; the sheet's Cancel
/// is then the only way out short of the limit.
@MainActor
final class OAuthConsentSession: NSObject, OAuthConsenting, ASWebAuthenticationPresentationContextProviding {
    var pollInterval: Duration = .seconds(2)
    var timeLimit: Duration = .seconds(600)

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "accountSetup")
    /// Never registered: nothing ever redirects to it, which is the point of polling.
    private static let callbackScheme = "nc-mail-oauth"

    func obtainConsent(at url: URL, isConnected: @escaping @MainActor () async -> Bool) async -> OAuthConsentResult {
        let closed = AsyncStream<Void>.makeStream()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { _, _ in
            // Any completion is the window going away: user cancel, or our own cancel() below.
            closed.continuation.yield()
            closed.continuation.finish()
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false

        let started = session.start()
        if !started {
            Self.logger.info("web authentication session did not start; using the default browser")
            closed.continuation.finish()
            NSWorkspace.shared.open(url)
        }

        let result = await withTaskGroup(of: OAuthConsentResult?.self) { group in
            // No `@MainActor` on the child: that closure trips the region-based isolation
            // checker; `poll` is main-actor isolated and hops there itself.
            group.addTask { [pollInterval, timeLimit] in
                await Self.poll(isConnected, every: pollInterval, for: timeLimit)
            }
            if started {
                group.addTask {
                    for await _ in closed.stream {}
                    return .aborted
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .aborted
        }
        session.cancel()
        Self.logger.info("consent finished: \(result == .granted ? "granted" : "aborted", privacy: .public)")
        return result
    }

    /// Granted as soon as the test passes; aborted at the limit or on cancellation.
    static func poll(
        _ isConnected: @escaping @MainActor () async -> Bool,
        every interval: Duration,
        for limit: Duration
    ) async -> OAuthConsentResult {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            do { try await Task.sleep(for: interval) } catch { return .aborted }
            if await isConnected() { return .granted }
        }
        return .aborted
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
