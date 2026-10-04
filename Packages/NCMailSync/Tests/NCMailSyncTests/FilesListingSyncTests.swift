// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// A clock a test moves by hand.
private final class FilesClock: Sendable {
    private let value = Mutex<Int64>(1_000)
    var now: Int64 { value.withLock { $0 } }
    func advance(_ seconds: Int64) { value.withLock { $0 += seconds } }
}

private struct FilesHarness {
    let base: ContactsHarness
    let clock = FilesClock()
    let sync: FilesListingSync
    let staging: URL

    var store: MailStore { base.store }
    var transport: FakeTransport { base.transport }
    var loginId: Int64 { base.loginId }

    init() async throws {
        base = try await ContactsHarness()
        let mail = MailClient(
            server: try #require(URL(string: "https://cloud.example.com")),
            credentials: BasicCredentials(loginName: "user", appPassword: "secret"),
            transport: base.transport,
            retryPolicy: .none
        )
        staging = FileManager.default.temporaryDirectory.appending(path: "FilesTests-\(UUID().uuidString)")
        let clock = clock
        sync = FilesListingSync(
            store: base.store, dav: base.client, client: mail, loginId: base.loginId, stagingDirectory: staging,
            now: { clock.now })
        await base.transport.stub(
            .propfind && .path("/remote.php/dav"), with: try .fixture("dav-current-user-principal.xml", status: 207))
    }

    func state(_ path: String) async throws -> FilesListingState? {
        try await store.filesListing(path: path, loginId: loginId).map(FilesListingState.init(record:))
    }

    func listingRequests() async -> Int {
        await transport.requests.filter { $0.httpMethod == "PROPFIND" && $0.url?.path.contains("/files/") == true }
            .count
    }
}

@Suite("FilesListingSync")
struct FilesListingSyncTests {
    @Test func writesTheRecordedRootListingFoldersFirst() async throws {
        let harness = try await FilesHarness()
        await harness.transport.stub(
            .propfind && .pathSuffix("/remote.php/dav/files/user") && .depth("1"),
            with: try .fixture("dav-files-root-ws33.xml", status: 207))

        await harness.sync.request(path: "/")
        await harness.sync.settle()

        let entries = try #require(try await harness.state("/")?.entries)
        #expect(entries.count == (try FilesFixture.rootResponses()) - 1)  // minus the folder itself
        #expect(entries.first?.isFolder == true)
        let kudos = try #require(entries.first { $0.name == "Kudos" })
        #expect(kudos.path == "/Kudos" && kudos.isFolder && kudos.mime == nil)
        #expect(kudos.size != nil)  // folders carry oc:size
        let receipt = try #require(entries.first { $0.name == "Receipt-2149-9589.pdf" })
        #expect(receipt.path == "/Receipt-2149-9589.pdf")
        #expect(receipt.mime == "application/pdf")
        #expect(receipt.size == 39_767)
        #expect(receipt.fileId == 222)
        #expect(receipt.modifiedAt == 1_790_676_484)  // Tue, 29 Sep 2026 10:08:04 GMT
        // Percent-escapes are decoded into the path the server APIs take.
        #expect(entries.contains { $0.path == "/Fixture OCS send.eml" })

        // Exactly the recorded request body.
        let request = try #require(
            await harness.transport.requests.first { $0.url?.path.contains("/files/") == true })
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("<oc:fileid/>") && body.contains("<d:getcontentlength/>"))
    }

    @Test func aFailureKeepsTheOldListing() async throws {
        let harness = try await FilesHarness()
        await harness.transport.stubSequence(
            .propfind && .pathSuffix("/remote.php/dav/files/user"),
            [try .fixture("dav-files-root-ws33.xml", status: 207), .status(503)])

        await harness.sync.request(path: "/")
        await harness.sync.settle()
        let before = try #require(try await harness.store.filesListing(path: "/", loginId: harness.loginId))

        harness.clock.advance(3_600)
        await harness.sync.request(path: "/", force: true)
        await harness.sync.settle()

        #expect(await harness.listingRequests() == 2)
        let after = try #require(try await harness.store.filesListing(path: "/", loginId: harness.loginId))
        #expect(after == before)
        #expect(FilesListingState(record: after).entries?.count == (try FilesFixture.rootResponses()) - 1)
    }

    @Test func aFailureWithNothingCachedWritesAFailedRow() async throws {
        let harness = try await FilesHarness()
        await harness.transport.stub(
            .propfind && .pathContains("ws33-no-such-folder"),
            with: try .fixture("dav-files-missing-ws33.xml", status: 404))

        await harness.sync.request(path: "/ws33-no-such-folder")
        await harness.sync.settle()

        #expect(try await harness.state("/ws33-no-such-folder") == .failed("notFound"))
        // One retry per five minutes, not a loop.
        await harness.sync.request(path: "/ws33-no-such-folder")
        await harness.sync.settle()
        #expect(await harness.listingRequests() == 1)
        harness.clock.advance(ServerResultKind.failureRetryAfter)
        await harness.sync.request(path: "/ws33-no-such-folder")
        await harness.sync.settle()
        #expect(await harness.listingRequests() == 2)
    }

    @Test func aFreshListingAnswersByItselfUntilItExpires() async throws {
        let harness = try await FilesHarness()
        await harness.transport.stub(
            .propfind && .pathSuffix("/remote.php/dav/files/user"),
            with: try .fixture("dav-files-root-ws33.xml", status: 207))

        await harness.sync.request(path: "/")
        await harness.sync.settle()
        await harness.sync.request(path: "")
        await harness.sync.settle()
        #expect(await harness.listingRequests() == 1)

        harness.clock.advance(FilesListingSync.expiry)
        await harness.sync.request(path: "/")
        await harness.sync.settle()
        #expect(await harness.listingRequests() == 2)
    }

    @Test func offlineSendsNothingAndTouchesNothing() async throws {
        let harness = try await FilesHarness()
        await harness.sync.apply(conditions: MirrorConditions(isOffline: true))

        await harness.sync.request(path: "/", force: true)
        await harness.sync.settle()

        #expect(await harness.transport.requests.isEmpty)
        #expect(try await harness.state("/") == nil)
    }

    @Test func aShareLinkLandsInAServerResultRow() async throws {
        let harness = try await FilesHarness()
        await harness.transport.stub(
            .method("POST") && .pathSuffix("/ocs/v2.php/apps/files_sharing/api/v1/shares"),
            with: try .fixture("share-link-created.json"))

        let outcome = await harness.sync.createShareLink(path: "Receipt-2149-9589.pdf")

        #expect(outcome.isSuccess)
        let row = try #require(
            try await harness.store.serverResult(
                kind: FilesListingSync.shareLinkKind, key: "/Receipt-2149-9589.pdf", loginId: harness.loginId))
        guard case .ready(let data) = try ServerResultPayload(payloadJSON: row.payloadJSON) else {
            Issue.record("not ready")
            return
        }
        #expect(data.objectValue?.string("url")?.contains("/s/") == true)
        let request = try #require(await harness.transport.requests.last)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("\"shareType\":3") && body.contains("Receipt-2149-9589.pdf"))
    }

    @Test func aFailedShareLinkWritesNothing() async throws {
        let harness = try await FilesHarness()
        await harness.transport.stub(.method("POST"), with: .status(404))

        let outcome = await harness.sync.createShareLink(path: "/gone.pdf")

        #expect(!outcome.isSuccess)
        #expect(
            try await harness.store.serverResult(
                kind: FilesListingSync.shareLinkKind, key: "/gone.pdf", loginId: harness.loginId) == nil)
    }

    @Test func insertImageRefusesTheWrongTypeOrSizeWithoutAsking() async throws {
        let harness = try await FilesHarness()
        let pdf = FilesEntry(path: "/a.pdf", name: "a.pdf", isFolder: false, mime: "application/pdf", size: 10)
        let huge = FilesEntry(
            path: "/a.png", name: "a.png", isFolder: false, mime: "image/png",
            size: FilesListingSync.maximumImageBytes + 1)
        let svg = FilesEntry(path: "/a.svg", name: "a.svg", isFolder: false, mime: "image/svg+xml", size: 10)

        for entry in [pdf, huge, svg] {
            #expect(!entry.isEmbeddableImage)
            #expect(!(await harness.sync.stageImage(entry)).isSuccess)
        }
        #expect(await harness.transport.requests.isEmpty)
    }

    @Test func insertImageStagesTheBytesAndRecordsWhere() async throws {
        let harness = try await FilesHarness()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        await harness.transport.stub(
            .method("GET") && .pathSuffix("/remote.php/dav/files/user/Photos/a b.png"),
            with: StubResponse(status: 200, body: bytes))
        let entry = FilesEntry(path: "/Photos/a b.png", name: "a b.png", isFolder: false, mime: "image/png", size: 8)

        #expect((await harness.sync.stageImage(entry)).isSuccess)
        let download = try #require(await harness.transport.requests.last { $0.httpMethod == "GET" })
        #expect(download.url?.absoluteString.hasSuffix("/remote.php/dav/files/user/Photos/a%20b.png") == true)

        let row = try #require(
            try await harness.store.serverResult(
                kind: FilesListingSync.imageKind, key: "/Photos/a b.png", loginId: harness.loginId))
        guard case .ready(let data) = try ServerResultPayload(payloadJSON: row.payloadJSON),
            let path = data.objectValue?.string("localPath")
        else {
            Issue.record("not ready")
            return
        }
        #expect(try Data(contentsOf: URL(filePath: path)) == bytes)
        #expect(path.hasSuffix(".png"))
        try? FileManager.default.removeItem(at: harness.staging)
    }

    @Test func aFilesAttachmentIsTheServersCloudShape() throws {
        let entry = FilesEntry(path: "/Docs/a.pdf", name: "a.pdf", isFolder: false, mime: "application/pdf", size: 5)
        let row = entry.draftAttachment(draftId: 7)
        #expect(row.kind == "cloud" && row.fileName == "a.pdf" && row.draftId == 7)
        let payload = try JSONDecoder().decode([String: String].self, from: Data(row.payloadJSON.utf8))
        #expect(payload == ["type": "cloud", "fileName": "/Docs/a.pdf"])
        // The send/draft body carries it verbatim — the shape the live server accepted
        // (`POST /api/drafts` turned it into a local attachment of the same file).
        #expect(
            OutboxRequest.payload(row)
                == .object(["type": .string("cloud"), "fileName": .string("/Docs/a.pdf")]))
    }

    @Test func pathsHaveOneSpelling() {
        #expect(FilesPath.normalize("") == "/")
        #expect(FilesPath.normalize("A//B/") == "/A/B")
        #expect(FilesPath.parent(of: "/A/B") == "/A")
        #expect(FilesPath.parent(of: "/A") == "/")
        #expect(FilesPath.appending("c d", to: "/A") == "/A/c d")
    }
}

/// The recorded listing grows whenever the recorder runs again (each run saves files), so
/// counts come from the fixture rather than a literal.
enum FilesFixture {
    static func rootResponses() throws -> Int {
        let text = String(decoding: try FixtureBytes.data("dav-files-root-ws33.xml"), as: UTF8.self)
        return text.components(separatedBy: "<d:response>").count - 1
    }
}
