// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

// The LLM-derived routes. Against a server with no language-model provider,
// `GET /api/thread/{id}/summary` and `GET /api/messages/{id}/smartreply` answer
// **204 with an empty body**, and `GET /api/thread/{id}/eventdata` answers
// `{"data": null}`. With a provider (verified live, 2026-10-04) summary and
// eventdata answer inside the `{"data": …}` envelope, but smartreply answers a
// **bare JSON array** of reply strings. All three types conform to
// `EmptyBodyRepresentable`, which turns the 204 into "no result".

/// The payload of `GET /api/thread/{id}/summary`: `JSONEnvelope<String?>`,
/// where the string is the summary text.
public typealias ThreadSummaryResponse = JSONEnvelope<String?>

/// `GET /api/thread/{id}/eventdata`'s payload: a suggested calendar event.
///
/// The live server (no LLM) sends `{"data": null}`; the populated element shape
/// comes from `lib/Service/AiIntegrations/AiIntegrationsService.php`, which
/// returns a summary and an agenda, so both fields stay optional until a
/// recording pins them.
public struct EventData: Decodable, Sendable, Hashable {
    public let summary: String?
    public let description: String?

    private enum CodingKeys: String, CodingKey {
        case summary
        case description
    }
}

/// `GET /api/messages/{messageId}/smartreply`: a bare array of reply strings,
/// `["Noted, thanks for info.", "Ok, I’ll update address."]` (verified live,
/// 2026-10-04, `message-smartreply-populated.json`) — not the `{"data": …}`
/// envelope its sibling routes use. 204 with an empty body when LLM processing
/// is off, which `EmptyBodyRepresentable` turns into no replies.
public struct SmartReplyResponse: Decodable, Sendable, Hashable, EmptyBodyRepresentable {
    public let replies: [String]

    public init(replies: [String]) {
        self.replies = replies
    }

    public init() {
        self.init(replies: [])
    }

    public init(from decoder: any Decoder) throws {
        replies = try decoder.singleValueContainer().decode([String].self)
    }
}
