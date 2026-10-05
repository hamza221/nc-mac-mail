// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog

/// `!` and "… ▸ Text blocks" over the mirrored `textBlock` rows: the login's own blocks and
/// the ones shared with it (§6.8, §7.1).
@MainActor
final class StoreTextBlockProvider: TextBlockProvider {
    private let store: MailStore
    private let loginId: Int64

    init(store: MailStore, loginId: Int64) {
        self.store = store
        self.loginId = loginId
    }

    func textBlocks(matching query: String) async -> [EditorTextBlock] {
        let blocks = (try? await store.textBlocks(loginId: loginId)) ?? []
        return Self.filter(blocks, query: query)
    }

    /// Every block, own first, for the dialog.
    func allBlocks() async -> [TextBlockRecord] {
        let blocks = (try? await store.textBlocks(loginId: loginId)) ?? []
        return blocks.sorted {
            ($0.isShared ? 1 : 0, $0.title.lowercased()) < ($1.isShared ? 1 : 0, $1.title.lowercased())
        }
    }

    nonisolated static func filter(_ blocks: [TextBlockRecord], query: String) -> [EditorTextBlock] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return
            blocks
            .filter { needle.isEmpty || $0.title.localizedStandardContains(needle) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { EditorTextBlock(title: $0.title, html: $0.content) }
    }
}

/// `/` and "… ▸ Smart picker" over mirrored `smartPickerResult` rows.
///
/// The row contract: providerId `__providers__` with term `""` holds the OCS
/// `GET /search/providers` list; each provider's search for a term is a row with that
/// provider's id and the unified-search payload (`{"entries":[{"title","resourceUrl"}]}`).
/// A view never fetches: it reads what the server-result engine wrote.
@MainActor
final class StoreSmartPickerProvider: SmartPickerProvider {
    static let providersKey = ServerResultFetcher.smartPickerProvidersId

    private let store: MailStore
    private let loginId: Int64
    /// Asks the server-result engine to (re)search; rows arrive later and are re-read.
    private let request: @MainActor (String) -> Void

    init(store: MailStore, loginId: Int64, request: @escaping @MainActor (String) -> Void) {
        self.store = store
        self.loginId = loginId
        self.request = request
    }

    func smartPickerLinks(matching query: String) async -> [SmartPickerLink] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [] }
        request(term)
        return await storedLinks(term: term)
    }

    /// What the mirror holds for a term right now, every provider merged.
    func storedLinks(term: String) async -> [SmartPickerLink] {
        let providers = await providerIds()
        var links: [SmartPickerLink] = []
        for provider in providers {
            guard let row = try? await store.smartPickerResult(providerId: provider, term: term, loginId: loginId)
            else { continue }
            links += Self.links(fromPayload: row.payloadJSON)
        }
        return links
    }

    private func providerIds() async -> [String] {
        guard let row = try? await store.smartPickerResult(providerId: Self.providersKey, term: "", loginId: loginId)
        else { return [] }
        return Self.providerIds(fromPayload: row.payloadJSON)
    }

    nonisolated static func providerIds(fromPayload json: String) -> [String] {
        struct Provider: Decodable { let id: String }
        guard let data = json.data(using: .utf8) else { return [] }
        return ((try? JSONDecoder().decode([Provider].self, from: data)) ?? []).map(\.id)
    }

    nonisolated static func links(fromPayload json: String) -> [SmartPickerLink] {
        struct Entry: Decodable {
            let title: String?
            let resourceUrl: String?
        }
        struct Payload: Decodable { let entries: [Entry] }
        guard let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }
        return payload.entries.compactMap { entry in
            guard let raw = entry.resourceUrl, let url = URL(string: raw), url.scheme == "https" || url.scheme == "http"
            else { return nil }
            return SmartPickerLink(title: entry.title ?? raw, url: url)
        }
    }
}
