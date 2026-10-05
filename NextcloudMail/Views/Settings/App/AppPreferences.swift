// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore

/// The §7 server preferences that are not the message list's, parsed from mirrored
/// `preference` rows with the web client's defaults for a key never set (`AppSettingsMenu.vue`
/// getters). The list's own keys stay in ``MessageListPreferences``.
struct AppPreferences: Equatable, Sendable {
    static let externalAvatarsKey = "external-avatars"
    static let searchPriorityBodyKey = "search-priority-body"
    static let autoMarkAsReadKey = "auto-mark-as-read"
    static let replyModeKey = "reply-mode"
    static let collectDataKey = "collect-data"
    static let internalAddressesKey = "internal-addresses"
    static let followUpKey = MessageListPreferences.followUpKey
    static let contextChatKey = "index-context-chat"
    static let layoutMessageViewKey = "layout-message-view"
    static let keys = [
        externalAvatarsKey, searchPriorityBodyKey, autoMarkAsReadKey, replyModeKey, collectDataKey,
        internalAddressesKey, followUpKey, contextChatKey, layoutMessageViewKey,
    ]

    var externalAvatars = true
    var searchPriorityBody = false
    var autoMarkAsRead = AutoMarkAsRead.afterThreeSeconds
    var replyAtBottom = false
    var collectData = true
    /// "Highlight external addresses".
    var highlightExternal = false
    var followUpReminders = true
    var contextChat = true
    /// "Show all messages in thread": `threaded` on, anything else (`singleton`, unset) off.
    var showAllMessagesInThread = false

    init() {}

    /// A boolean the web reads as `getPreference(key, 'true') === 'true'` is on unless the
    /// value is something other than `true`; one read with default `'false'` is on only when
    /// it is exactly `true`. Both spelled out per key, because the two are not symmetric for a
    /// value this version does not know.
    init(values: [String: String]) {
        externalAvatars = (values[Self.externalAvatarsKey] ?? "true") == "true"
        searchPriorityBody = values[Self.searchPriorityBodyKey] == "true"
        autoMarkAsRead = values[Self.autoMarkAsReadKey].flatMap(AutoMarkAsRead.init(rawValue:)) ?? .afterThreeSeconds
        replyAtBottom = values[Self.replyModeKey] == "bottom"
        collectData = (values[Self.collectDataKey] ?? "true") == "true"
        highlightExternal = values[Self.internalAddressesKey] == "true"
        followUpReminders = (values[Self.followUpKey] ?? "true") == "true"
        contextChat = (values[Self.contextChatKey] ?? "true") == "true"
        showAllMessagesInThread = values[Self.layoutMessageViewKey] == "threaded"
    }
}

/// `auto-mark-as-read`, in milliseconds as the web saves it.
enum AutoMarkAsRead: String, CaseIterable, Identifiable, Sendable {
    case immediately = "0"
    case afterThreeSeconds = "3000"
    case afterThirtySeconds = "30000"
    case manually = "-1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .afterThreeSeconds: String(localized: "After 3 seconds")
        case .afterThirtySeconds: String(localized: "After 30 seconds")
        case .manually: String(localized: "Manually")
        }
    }

    /// The reader's local delay (`MessageActions.messageOpened`), written in the same action.
    var localDelay: MarkAsReadDelay {
        switch self {
        case .immediately: .immediately
        case .afterThreeSeconds: .after(seconds: 3)
        case .afterThirtySeconds: .after(seconds: 30)
        case .manually: .manually
        }
    }
}

/// The "Add internal address" field, read the way the web's dialog reads it: a leading `@`
/// names a domain, an address with a local part names one person, and a bare host is a
/// domain too.
enum InternalAddressInput {
    struct Parsed: Equatable, Sendable {
        let address: String
        /// `domain` or `individual`, the server's spelling.
        let type: String
    }

    static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.hasPrefix("@") {
            let domain = String(trimmed.dropFirst())
            guard !domain.isEmpty, !domain.contains("@") else { return nil }
            return Parsed(address: domain, type: "domain")
        }
        if let at = trimmed.firstIndex(of: "@") {
            let local = trimmed[..<at]
            let host = trimmed[trimmed.index(after: at)...]
            guard !local.isEmpty, !host.isEmpty, !host.contains("@") else { return nil }
            return Parsed(address: trimmed, type: "individual")
        }
        return Parsed(address: trimmed, type: "domain")
    }

    /// Domains first, then addresses, each alphabetically — the web's list order.
    static func sorted(_ records: [InternalAddressRecord]) -> [InternalAddressRecord] {
        records.sorted { lhs, rhs in
            if (lhs.type == "domain") != (rhs.type == "domain") { return lhs.type == "domain" }
            return lhs.address.localizedStandardCompare(rhs.address) == .orderedAscending
        }
    }
}

/// One sharee search hit (`ServerResultKind.sharees`).
struct ShareeSuggestion: Equatable, Hashable, Sendable, Identifiable {
    let shareWith: String
    /// `user` or `group`.
    let type: String
    let displayName: String

    var id: String { "\(type):\(shareWith)" }

    /// The payload's array, minus the signed-in user and anyone the block is already shared
    /// with, users before groups. The server already drops the asking user from its answer;
    /// filtering again costs nothing and covers a login name that differs in case.
    static func suggestions(from payload: AnyJSON?, excluding: Set<String>, selfUserId: String) -> [ShareeSuggestion] {
        guard case .array(let items)? = payload else { return [] }
        let parsed: [ShareeSuggestion] = items.compactMap { item in
            guard case .object(let fields) = item, case .string(let shareWith)? = fields["shareWith"] else {
                return nil
            }
            let type: String = if case .string(let value)? = fields["type"] { value } else { "user" }
            let name: String =
                if case .string(let value)? = fields["displayName"], !value.isEmpty { value } else { shareWith }
            return ShareeSuggestion(shareWith: shareWith, type: type, displayName: name)
        }
        var seen: Set<String> = []
        let filtered = parsed.filter { suggestion in
            guard !excluding.contains(suggestion.shareWith) else { return false }
            guard
                !(suggestion.type == "user" && suggestion.shareWith.caseInsensitiveCompare(selfUserId) == .orderedSame)
            else { return false }
            return seen.insert(suggestion.id).inserted
        }
        return filtered.filter { $0.type == "user" } + filtered.filter { $0.type != "user" }
    }
}

enum TextBlockFormatting {
    /// The list's one-line preview: the stored HTML without tags, entities decoded for the
    /// handful the editor writes, whitespace collapsed. Not a renderer — a preview never
    /// needs one, and parsing HTML through WebKit for a list row would be absurd.
    static func preview(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Shares in the web's order: users, then groups.
    static func sortedShares(_ shares: [TextBlockShareRecord]) -> [TextBlockShareRecord] {
        shares.filter { $0.type == "user" } + shares.filter { $0.type != "user" }
    }
}

/// One row of the S/MIME table, read out of the mirrored record.
struct SmimeCertificateRow: Identifiable, Equatable, Sendable {
    let remoteId: Int64
    let name: String
    let emailAddress: String
    let validUntil: Date?

    var id: Int64 { remoteId }

    init(_ record: SmimeCertificateRecord) {
        remoteId = record.remoteId
        emailAddress = record.emailAddress
        validUntil = record.notAfter.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let info = try? JSONDecoder().decode(Info.self, from: Data(record.infoJSON.utf8))
        name = info?.commonName.flatMap { $0.isEmpty ? nil : $0 } ?? record.emailAddress
    }

    private struct Info: Decodable {
        let commonName: String?
    }
}

/// "Set as default mail app": whether this bundle is the one Launch Services resolves for a
/// `mailto:` URL.
///
/// Paths are compared after resolving symlinks, because Launch Services and `Bundle.main` can
/// spell the same bundle differently (`/Applications` through a symlinked volume, a trailing
/// slash). A second copy of the app elsewhere on disk is a different bundle, and the button
/// says so: setting it again points `mailto:` at the copy that is running.
struct DefaultMailAppCheck {
    var handler: () -> URL?
    var bundleURL: URL

    func isDefault() -> Bool {
        guard let handler = handler() else { return false }
        return Self.normalized(handler) == Self.normalized(bundleURL)
    }

    /// The button's title: what it would do, or that it is already done.
    static func label(isDefault: Bool) -> String {
        isDefault ? String(localized: "Default mail app") : String(localized: "Set as default mail app")
    }

    static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
