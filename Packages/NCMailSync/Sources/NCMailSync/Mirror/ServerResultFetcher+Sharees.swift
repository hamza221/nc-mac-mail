// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet

/// The `sharees` row's data: users and groups the term matched, exact matches first, then
/// the fuzzy ones; users before groups within each. Each entry is
/// `{"shareWith", "type": "user"|"group", "displayName"}`, the OCS `label` becoming
/// `displayName`. No match at all is an empty row.
func shareesPayload(_ data: AnyJSON) -> ServerResultPayload {
    guard case .object(let fields) = data else { return .empty }
    var exact: [String: AnyJSON] = [:]
    if case .object(let exactFields)? = fields["exact"] { exact = exactFields }
    let entries =
        shareeEntries(exact["users"], type: "user") + shareeEntries(exact["groups"], type: "group")
        + shareeEntries(fields["users"], type: "user") + shareeEntries(fields["groups"], type: "group")
    return entries.isEmpty ? .empty : .ready(.array(entries))
}

private func shareeEntries(_ list: AnyJSON?, type: String) -> [AnyJSON] {
    guard case .array(let items)? = list else { return [] }
    return items.compactMap { item in
        guard case .object(let fields) = item,
            case .object(let value)? = fields["value"],
            case .string(let shareWith)? = value["shareWith"]
        else { return nil }
        let displayName: String
        if case .string(let label)? = fields["label"], !label.isEmpty {
            displayName = label
        } else {
            displayName = shareWith
        }
        return .object([
            "shareWith": .string(shareWith),
            "type": .string(type),
            "displayName": .string(displayName),
        ])
    }
}

extension Endpoint where Response == OCSResponse<AnyJSON> {
    /// `GET /ocs/v2.php/apps/files_sharing/api/v1/sharees` — users (`shareType` 0) and
    /// groups (1) matching `search`, kept as the server sent it for ``shareesPayload(_:)``.
    static func sharees(search: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "sharees",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/apps/files_sharing/api/v1/sharees",
            query: [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "itemType", value: "file"),
                URLQueryItem(name: "search", value: search),
                URLQueryItem(name: "shareType[]", value: "0"),
                URLQueryItem(name: "shareType[]", value: "1"),
            ],
            isRetryable: true
        )
    }
}
