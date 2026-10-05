// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

/// The composer's "/" Smart Picker (§6.8), the ADR-0067 way: the fetcher writes
/// `smartPickerResult` rows and the composer observes them
/// (`MailStore.observeSmartPickerResult(providerId:term:loginId:)`).
///
/// Two row shapes:
/// - provider list: `providerId` ``smartPickerProvidersId``, `term` `""`, payload the OCS
///   `data` list of `GET /ocs/v2.php/search/providers` as the server sent it;
/// - one provider search: `(providerId, term)`, payload `{"entries":[{title, subline,
///   resourceUrl}]}` mapped from `GET /ocs/v2.php/search/providers/{id}/search?term=`.
///
/// Offline nothing is sent; a failure writes nothing, so the last answer stays.
extension ServerResultFetcher {
    /// The `providerId` of the provider-list row.
    public static let smartPickerProvidersId = "__providers__"
    /// How long a provider list is trusted before ``requestSmartPicker(term:)`` refreshes it.
    static let smartPickerProvidersExpiry: Int64 = 24 * 60 * 60
    /// At most this many provider searches run at once.
    static let smartPickerConcurrency = 4

    /// Refreshes the provider list row unconditionally; returns immediately.
    public func requestSmartPickerProviders() {
        _ = providersTask(force: true)
    }

    /// Searches every provider for `term`, refreshing the provider list first when it is
    /// missing or older than a day; returns immediately. A second call for the same term
    /// while one is in flight joins it.
    public func requestSmartPicker(term: String) {
        guard !conditions.isOffline else {
            MirrorLog.mirror.debug("smart picker skipped: offline")
            return
        }
        let id = "smartPicker|\(term)"
        guard inFlight[id] == nil else { return }
        inFlight[id] = Task(priority: .userInitiated) {
            if let providers = self.providersTask(force: false) { await providers.value }
            await self.searchAll(term: term)
            self.finished(id)
        }
    }

    /// The provider-list request, joined when one is in flight; nil offline.
    private func providersTask(force: Bool) -> Task<Void, Never>? {
        guard !conditions.isOffline else {
            MirrorLog.mirror.debug("smart picker providers skipped: offline")
            return nil
        }
        let id = "smartPicker.providers"
        if let running = inFlight[id] { return running }
        let task = Task(priority: .userInitiated) {
            await self.refreshProviders(force: force)
            self.finished(id)
        }
        inFlight[id] = task
        return task
    }

    private func refreshProviders(force: Bool) async {
        do {
            let loginId = try await resolveLoginId()
            if !force,
                let row = try await store.smartPickerResult(
                    providerId: Self.smartPickerProvidersId, term: "", loginId: loginId),
                now() - row.fetchedAt < Self.smartPickerProvidersExpiry
            {
                return
            }
            let list = try await client.get(.searchProviders).data
            try await store.upsert(
                smartPickerResult: SmartPickerResultRecord(
                    loginId: loginId,
                    providerId: Self.smartPickerProvidersId,
                    term: "",
                    payloadJSON: try smartPickerJSON(list),
                    fetchedAt: now()
                )
            )
        } catch is CancellationError {
            return
        } catch {
            MirrorLog.mirror.info("smart picker providers failed: \(describeSync(error), privacy: .public)")
        }
    }

    private func searchAll(term: String) async {
        let loginId: Int64
        let providerIds: [String]
        do {
            loginId = try await resolveLoginId()
            guard
                let row = try await store.smartPickerResult(
                    providerId: Self.smartPickerProvidersId, term: "", loginId: loginId)
            else { return }
            providerIds = smartPickerProviderIds(
                try JSONDecoder().decode(AnyJSON.self, from: Data(row.payloadJSON.utf8)))
        } catch {
            MirrorLog.mirror.error("smart picker: provider list unreadable: \(describeSync(error), privacy: .public)")
            return
        }
        let client = client
        let store = store
        let now = now
        await withTaskGroup(of: Void.self) { group in
            var pending = providerIds.makeIterator()
            for _ in 0..<Self.smartPickerConcurrency {
                guard let providerId = pending.next() else { break }
                group.addTask {
                    await Self.search(providerId, term: term, loginId: loginId, client: client, store: store, now: now)
                }
            }
            while await group.next() != nil {
                guard let providerId = pending.next() else { continue }
                group.addTask {
                    await Self.search(providerId, term: term, loginId: loginId, client: client, store: store, now: now)
                }
            }
        }
    }

    private static func search(
        _ providerId: String,
        term: String,
        loginId: Int64,
        client: MailClient,
        store: MailStore,
        now: @Sendable () -> Int64
    ) async {
        do {
            let result = try await client.get(.pickerSearch(providerId: providerId, term: term)).data
            let entries = AnyJSON.array(
                result.entries.map { entry in
                    .object([
                        "title": entry.title.json,
                        "subline": entry.subline.json,
                        "resourceUrl": entry.resourceUrl.json,
                    ])
                }
            )
            try await store.upsert(
                smartPickerResult: SmartPickerResultRecord(
                    loginId: loginId,
                    providerId: providerId,
                    term: term,
                    payloadJSON: try smartPickerJSON(.object(["entries": entries])),
                    fetchedAt: now()
                )
            )
        } catch is CancellationError {
            return
        } catch {
            MirrorLog.mirror.info("smart picker search failed: \(describeSync(error), privacy: .public)")
        }
    }
}

/// The `id` of every provider in the provider-list payload, in server order.
func smartPickerProviderIds(_ list: AnyJSON) -> [String] {
    guard case .array(let providers) = list else { return [] }
    return providers.compactMap { provider in
        guard case .object(let fields) = provider, case .string(let id)? = fields["id"] else { return nil }
        return id
    }
}

private func smartPickerJSON(_ value: AnyJSON) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

extension Endpoint where Response == OCSResponse<AnyJSON> {
    /// `GET /ocs/v2.php/search/providers` — every unified-search provider, kept as the
    /// server sent it because the provider-list row is that list verbatim.
    static var searchProviders: Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "searchProviders",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/search/providers",
            isRetryable: true
        )
    }
}
