// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// The IMAP flags of one message.
///
/// One type covers both the envelope and the body. Against Mail 5.12.0-rc.1 the
/// body endpoint returns an object, exactly like the envelope, and not the array
/// `docs/reference/api-payloads.md` used to claim. The two objects differ only
/// in their keys: the body omits `$junk` and `$notjunk`, so those two default to
/// false rather than being required.
///
/// The array form is still decoded, because `PUT .../flags` accepts a flag name
/// list and older controllers emitted one. An unknown name is ignored rather
/// than fatal: a new server flag must not break reading mail.
public struct MessageFlags: Decodable, Sendable, Hashable {
    public var seen = false
    public var flagged = false
    public var answered = false
    public var deleted = false
    public var draft = false
    public var forwarded = false
    public var hasAttachments = false
    public var important = false
    public var junk = false
    public var notJunk = false
    public var mdnSent = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case seen
        case flagged
        case answered
        case deleted
        case draft
        case forwarded
        case hasAttachments
        case important
        // Leading `$` is part of the key, so it has to be spelled out.
        case junk = "$junk"
        case notJunk = "$notjunk"
        case mdnSent = "$mdnsent"
    }

    public init(from decoder: any Decoder) throws {
        if let names = try? [String](from: decoder) {
            self.init(names: names)
            return
        }
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seen = try container.decodeLenientBool(forKey: .seen)
        flagged = try container.decodeLenientBool(forKey: .flagged)
        answered = try container.decodeLenientBool(forKey: .answered)
        deleted = try container.decodeLenientBool(forKey: .deleted)
        draft = try container.decodeLenientBool(forKey: .draft)
        forwarded = try container.decodeLenientBool(forKey: .forwarded)
        hasAttachments = try container.decodeLenientBool(forKey: .hasAttachments)
        important = try container.decodeLenientBool(forKey: .important)
        junk = try container.decodeLenientBool(forKey: .junk)
        notJunk = try container.decodeLenientBool(forKey: .notJunk)
        mdnSent = try container.decodeLenientBool(forKey: .mdnSent)
    }

    private init(names: [String]) {
        self.init()
        for name in names {
            switch name.lowercased() {
            case "\\seen", "seen": seen = true
            case "\\flagged", "flagged": flagged = true
            case "\\answered", "answered": answered = true
            case "\\deleted", "deleted": deleted = true
            case "\\draft", "draft": draft = true
            case "$forwarded", "forwarded": forwarded = true
            case "hasattachments": hasAttachments = true
            case "$important", "important": important = true
            case "$junk", "junk": junk = true
            case "$notjunk", "notjunk": notJunk = true
            case "$mdnsent", "mdnsent": mdnSent = true
            default: continue
            }
        }
    }
}
