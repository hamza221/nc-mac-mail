// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The Smart Picker rows the composer reads: the provider list verbatim, one row per
/// provider search, nothing deleted by a failure, nothing sent offline.
@Suite("Smart Picker fetcher")
struct SmartPickerFetcherTests {
    static let providersRoute = RequestMatcher.path("/ocs/v2.php/search/providers")
    static let searchRoute = RequestMatcher.pathSuffix("/search")
    static let providersId = ServerResultFetcher.smartPickerProvidersId

    func row(
        _ f: ServerResultFetcherTests.Fixture, _ providerId: String, _ term: String
    ) async throws
        -> SmartPickerResultRecord?
    {
        try await f.seeded.store.smartPickerResult(providerId: providerId, term: term, loginId: f.loginId)
    }

    func decode(_ row: SmartPickerResultRecord?) throws -> AnyJSON {
        try JSONDecoder().decode(AnyJSON.self, from: Data(try #require(row).payloadJSON.utf8))
    }

    /// The provider ids of the recorded list, read independently of the code under test.
    func recordedProviderIds() throws -> [String] {
        let data = try FixtureBytes.data("search-providers.json")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (json?["ocs"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { $0["id"] as? String }
    }

    @Test("the provider list is one row, the OCS data list verbatim")
    func providerList() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.providersRoute, with: try .fixture("search-providers.json"))
        await f.fetcher.requestSmartPickerProviders()
        await f.fetcher.settle()

        let payload = try decode(try await row(f, Self.providersId, ""))
        guard case .array(let providers) = payload else { Issue.record("not a list"); return }
        let ids = try recordedProviderIds()
        #expect(!ids.isEmpty)
        #expect(smartPickerProviderIds(payload) == ids)
        #expect(providers.count == ids.count)
    }

    @Test("a term searches every provider and writes {entries:[{title, subline, resourceUrl}]}")
    func searchRows() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.providersRoute, with: try .fixture("search-providers.json"))
        await f.transport.stub(Self.searchRoute, with: try .fixture("picker-search-files.json"))
        await f.fetcher.requestSmartPicker(term: "fixture")
        await f.fetcher.settle()

        let ids = try recordedProviderIds()
        #expect(ids.contains("files"))
        #expect(await f.transport.sendCount == 1 + ids.count)
        let recorded = try FixtureBytes.decode(OCSResponse<UnifiedSearchResult>.self, from: "picker-search-files.json")
        for id in ids {
            let payload = try decode(try await row(f, id, "fixture"))
            guard case .object(let fields) = payload, case .array(let entries)? = fields["entries"] else {
                Issue.record("\(id): no entries list")
                continue
            }
            #expect(entries.count == recorded.data.entries.count)
            if let first = recorded.data.entries.first, case .object(let entry)? = entries.first {
                #expect(entry["title"] == first.title.json)
                #expect(entry["subline"] == first.subline.json)
                #expect(entry["resourceUrl"] == first.resourceUrl.json)
                #expect(entry.count == 3)
            }
        }

        // The list is fresh for a day: the next term searches without asking for it again.
        await f.fetcher.requestSmartPicker(term: "other")
        await f.fetcher.settle()
        #expect(await f.transport.sendCount == 1 + 2 * ids.count)
    }

    @Test("failures never delete rows: the provider list and the searches keep their answers")
    func failureKeepsRows() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stubSequence(Self.providersRoute, [try .fixture("search-providers.json"), .status(503)])
        await f.transport.stub(Self.searchRoute, with: try .fixture("picker-search-files.json"))
        await f.fetcher.requestSmartPicker(term: "fixture")
        await f.fetcher.settle()
        let providers = try await row(f, Self.providersId, "")
        let files = try await row(f, "files", "fixture")
        #expect(providers != nil && files != nil)

        await f.transport.stub(Self.searchRoute, with: .status(500))
        await f.fetcher.requestSmartPickerProviders()
        await f.fetcher.settle()
        await f.fetcher.requestSmartPicker(term: "fixture")
        await f.fetcher.settle()

        #expect(try await row(f, Self.providersId, "") == providers)
        #expect(try await row(f, "files", "fixture") == files)
    }

    @Test("offline: nothing is sent and the rows stay")
    func offline() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.providersRoute, with: try .fixture("search-providers.json"))
        await f.transport.stub(Self.searchRoute, with: try .fixture("picker-search-files.json"))
        await f.fetcher.requestSmartPicker(term: "fixture")
        await f.fetcher.settle()
        let sent = await f.transport.sendCount
        let files = try await row(f, "files", "fixture")

        await f.fetcher.apply(conditions: MirrorConditions(isOffline: true))
        await f.fetcher.requestSmartPickerProviders()
        await f.fetcher.requestSmartPicker(term: "fixture")
        await f.fetcher.requestSmartPicker(term: "new")
        await f.fetcher.settle()

        #expect(await f.transport.sendCount == sent)
        #expect(try await row(f, "files", "fixture") == files)
        #expect(try await row(f, "files", "new") == nil)
    }

    @Test("two requests for the same term while one is in flight send one set of requests")
    func inFlightJoin() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.providersRoute, with: try .fixture("search-providers.json"))
        await f.transport.stub(Self.searchRoute, with: try .fixture("picker-search-files.json"))
        let (fetcher, gate) = try f.gated(holding: Self.providersRoute)
        await fetcher.requestSmartPicker(term: "fixture")
        await gate.waitForHeld()
        await fetcher.requestSmartPicker(term: "fixture")
        await fetcher.requestSmartPickerProviders()
        await gate.open()
        await fetcher.settle()

        #expect(await f.transport.sendCount == 1 + (try recordedProviderIds()).count)
    }
}
