// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

// The LLM-derived routes. Against a server with no language-model provider —
// the live test server — `GET /api/thread/{id}/summary` and
// `GET /api/messages/{id}/smartreply` answer **204 with an empty body**, and
// `GET /api/thread/{id}/eventdata` answers `{"data": null}`. All three decode
// through `JSONEnvelope` with an optional payload, whose
// `EmptyBodyRepresentable` conformance turns the 204 into "no result".

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

/// `GET /api/messages/{messageId}/smartreply`.
///
/// 204 when LLM processing is off (verified live). The populated shape is
/// unverified — no provider to record against — so the payload stays `AnyJSON`
/// rather than a guessed pair of reply fields.
public typealias SmartReplyResponse = JSONEnvelope<AnyJSON?>
