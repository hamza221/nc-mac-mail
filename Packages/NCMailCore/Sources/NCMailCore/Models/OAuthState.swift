// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `POST /api/oauth/state`, inside the `JSONEnvelope`.
///
/// Verified live (Mail 5.12): `{"status":"success","data":{"state":"1.…"}}`.
/// The state is a signed token the OAuth redirect hands back; the client never
/// parses it, only carries it.
public struct OAuthState: Decodable, Sendable, Hashable {
    public let state: String

    private enum CodingKeys: String, CodingKey {
        case state
    }
}
