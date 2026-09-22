// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Why `LoginFlow` did not produce credentials.
///
/// [S-01](../../../../docs/product/user-stories.md#s-01-sign-in-ws-01) asks for three
/// distinguishable failures at the field, not one generic "couldn't sign in":
/// unreachable, not a Nextcloud instance, and no Mail app installed. The other
/// two cases belong to the flow itself, not to what the server said.
public enum LoginError: Error, Sendable, Equatable {
    /// A transport-level failure: DNS, connection refused, TLS, timeout. The
    /// server URL may be entirely wrong, or the network may be down.
    case unreachable

    /// A response came back, but not shaped like Login Flow v2: no `poll`
    /// object, a login page instead of JSON, or a route that does not exist.
    /// Covers both "not Nextcloud" and "Nextcloud too old for this flow" —
    /// the user-facing message is the same either way.
    case notNextcloud

    /// Login Flow v2 completed and the app password works, but
    /// `/index.php/apps/mail/api/accounts` 404s: the instance has no Mail app,
    /// or it is disabled for this user.
    case mailAppMissing

    /// Five minutes passed with no poll success. The user never finished, or
    /// abandoned, the browser step.
    case timedOut

    /// `LoginFlow.cancel()` was called while `start` or `awaitCompletion` was
    /// in flight.
    case cancelled

    /// The server answered with an HTTP status this flow does not otherwise
    /// interpret.
    case server(status: Int)
}
