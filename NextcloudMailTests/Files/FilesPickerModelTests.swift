// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailSync
import Synchronization
import Testing

@testable import NextcloudMail

/// Answers the two DAV requests a listing needs from the recorded fixtures, and counts.
/// `FakeTransport` is the package's; the app's test bundle never links it (ADR-0029).
private final class FilesRoutingTransport: MailTransport {
    private let sent = Mutex(0)
    var count: Int { sent.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.withLock { $0 += 1 }
        guard let url = request.url else { throw MailError.transport(URLError(.badURL)) }
        let fixture = url.path.contains("/files/") ? "dav-files-root-ws33.xml" : "dav-current-user-principal.xml"
        let body = try FixtureBytes.data(fixture)
        guard let response = HTTPURLResponse(url: url, statusCode: 207, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw MailError.transport(URLError(.badServerResponse)) }
        return (body, response)
    }
}

@MainActor
@Suite("Files picker model")
struct FilesPickerModelTests {
    private struct Rig {
        let store: MailStore
        let loginId: Int64
        let transport = FilesRoutingTransport()
        let sync: FilesListingSync

        init() async throws {
            store = try MailStore.inMemory()
            let server = try #require(URL(string: "https://cloud.example.com"))
            let credentials = BasicCredentials(loginName: "user", appPassword: "secret")
            loginId = try #require(try await store.ensureLogin(ServerIdentity(serverURL: server, loginName: "user")).id)
            sync = FilesListingSync(
                store: store,
                dav: DAVClient(server: server, credentials: credentials, transport: transport),
                client: MailClient(server: server, credentials: credentials, transport: transport),
                loginId: loginId
            )
        }
    }

    private func waitForEntries(_ model: FilesPickerModel) async throws -> [FilesEntry] {
        for _ in 0..<200 {
            if case .entries(let entries) = model.content { return entries }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("no listing arrived")
        return []
    }

    @Test func offlineShowsTheCachedListingWithANote() async throws {
        let rig = try await Rig()
        let online = FilesPickerModel(store: rig.store, loginId: rig.loginId, sync: rig.sync)
        online.open("/")
        let fetched = try await waitForEntries(online)
        online.stop()
        #expect(fetched.contains { $0.path == "/Receipt-2149-9589.pdf" } && fetched.first?.isFolder == true)
        #expect(online.offlineNote(isOffline: false) == nil)
        let sentOnline = rig.transport.count

        await rig.sync.apply(conditions: MirrorConditions(isOffline: true))
        let offline = FilesPickerModel(store: rig.store, loginId: rig.loginId, sync: rig.sync)
        offline.open("/")
        offline.request(force: true)
        let cached = try await waitForEntries(offline)

        #expect(cached == fetched)
        #expect(offline.offlineNote(isOffline: true)?.hasPrefix("Offline — showing the listing from") == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.transport.count == sentOnline)  // offline sends nothing
        offline.stop()
    }

    @Test func offlineWithNothingCachedSaysSo() async throws {
        let rig = try await Rig()
        await rig.sync.apply(conditions: MirrorConditions(isOffline: true))
        let model = FilesPickerModel(store: rig.store, loginId: rig.loginId, sync: rig.sync)
        model.open("/Kudos")
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.content == .pending)
        #expect(model.offlineNote(isOffline: true) == "Offline — this folder has not been loaded yet.")
        #expect(rig.transport.count == 0)
        model.stop()
    }

    @Test func breadcrumbsWalkFromHome() async throws {
        let rig = try await Rig()
        let model = FilesPickerModel(store: rig.store, loginId: rig.loginId, sync: nil)
        model.open("Documents/Invoices/")
        #expect(model.path == "/Documents/Invoices")
        #expect(model.breadcrumbs.map(\.path) == ["/", "/Documents", "/Documents/Invoices"])
        #expect(model.breadcrumbs.map(\.title) == ["Home", "Documents", "Invoices"])
        model.stop()
    }

    @Test func theTypeFilterKeepsFoldersAndMatchesTheInsertImageSet() {
        let folder = FilesEntry(path: "/A", name: "A", isFolder: true)
        let png = FilesEntry(path: "/a.png", name: "a.png", isFolder: false, mime: "image/png")
        let svg = FilesEntry(path: "/a.svg", name: "a.svg", isFolder: false, mime: "image/svg+xml")
        let pdf = FilesEntry(path: "/a.pdf", name: "a.pdf", isFolder: false, mime: "application/pdf")
        #expect(FilesTypeFilter.images.matches(folder))
        #expect(FilesTypeFilter.images.matches(png) && !FilesTypeFilter.images.matches(svg))
        #expect(FilesTypeFilter.documents.matches(pdf) && !FilesTypeFilter.documents.matches(png))
    }

    @Test func insertImageRefusesBeforeAskingTheServer() {
        let big = FilesEntry(
            path: "/a.jpg", name: "a.jpg", isFolder: false, mime: "image/jpeg",
            size: FilesListingSync.maximumImageBytes + 1)
        let svg = FilesEntry(path: "/a.svg", name: "a.svg", isFolder: false, mime: "image/svg+xml", size: 1)
        let ok = FilesEntry(path: "/a.webp", name: "a.webp", isFolder: false, mime: "image/webp", size: 1)
        #expect(FilesActions.refusal(for: big) == .tooLarge)
        #expect(FilesActions.refusal(for: svg) == .unsupportedType)
        #expect(FilesActions.refusal(for: ok) == nil)
    }
}
