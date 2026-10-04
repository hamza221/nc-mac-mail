// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Security
import Testing

@testable import NextcloudMail

/// The Share extension writes with `SharedInboxDrop`; the composer reads with WS-27's
/// `SharedInbox`. These run the writer and the reader the two targets compile, over the
/// real inbox location, so a drift in either half of the format fails here.
@Suite("Share extension hand-off", .serialized)
@MainActor
struct ShareHandoffTests {
    private static func sourceFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws42-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func aSharedItemBecomesTheComposersSeed() async throws {
        let fixture = try await SystemFixture.make()
        let inbox = try #require(SharedInbox.inboxURL)
        let pdf = try Self.sourceFile(named: "report.pdf", contents: "%PDF-1.4")
        let note = try Self.sourceFile(named: "report.pdf", contents: "second file, same name")
        let page = try #require(URL(string: "https://example.com/article"))

        let itemId = try SharedInboxDrop.write(
            subject: "An article",
            text: "Worth a read",
            urls: [page],
            files: [
                SharedInboxDrop.SharedFile(source: pdf, name: "report.pdf", mime: "application/pdf"),
                SharedInboxDrop.SharedFile(source: note, name: "report.pdf", mime: nil),
            ],
            inbox: inbox)
        #expect(SharedInboxDrop.pendingItemIds(inbox: inbox).contains(itemId))
        // The link the extension opens is the request the app routes.
        let link = try #require(SystemLink.shared(inboxItemId: itemId).url.flatMap(SystemLink.init(url:)))
        #expect(link == .shared(inboxItemId: itemId))

        let seed = await ComposeSeedBuilder.seed(
            for: .shared(inboxItemId: itemId), store: fixture.store, preferredAccountId: nil)

        #expect(seed.failure == nil)
        #expect(seed.accountId == fixture.accountId)
        #expect(seed.subject == "An article")
        #expect(seed.body == "Worth a read\nhttps://example.com/article")
        #expect(seed.attachments.map(\.fileName) == ["report.pdf", "report.pdf"])
        #expect(seed.attachments.first?.mime == "application/pdf")
        let staged = try seed.attachments.map { try #require($0.localPath) }
        #expect(
            try staged.map { try String(contentsOfFile: $0, encoding: .utf8) } == [
                "%PDF-1.4", "second file, same name",
            ])
        // Taken exactly once: the item is gone, and a second open says so.
        #expect(!SharedInboxDrop.pendingItemIds(inbox: inbox).contains(itemId))
        let again = await ComposeSeedBuilder.seed(
            for: .shared(inboxItemId: itemId), store: fixture.store, preferredAccountId: nil)
        #expect(again.failure == "The shared item could not be found.")
        for path in staged { AttachmentStaging.discard(path: path) }
    }

    /// `item.json` is written last, so a half-written item is never pending.
    @Test func aFailedCopyLeavesNothingBehind() throws {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws42-\(UUID().uuidString)", isDirectory: true)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ws42-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try SharedInboxDrop.write(
                text: "x", files: [SharedInboxDrop.SharedFile(source: missing, name: "gone.txt")], inbox: inbox)
        }
        #expect(SharedInboxDrop.pendingItemIds(inbox: inbox).isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.isEmpty ?? true)
    }

    @Test func textOnlyItemsDecodeWithTheReadersDefaults() throws {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws42-\(UUID().uuidString)", isDirectory: true)
        let itemId = try SharedInboxDrop.write(text: "Just text", inbox: inbox)
        let taken = try #require(SharedInbox.take(itemId: itemId, inbox: inbox))
        #expect(taken.text == "Just text")
        #expect(taken.subject == nil)
        #expect(taken.urls.isEmpty)
        #expect(taken.stagedFiles.isEmpty)
    }
}

@Suite("App group")
struct AppGroupTests {
    /// The code names the group the running app is entitled to, and WS-27's reader uses it.
    @Test func theIdentifierIsTheEntitlement() throws {
        #expect(SharedInbox.appGroupIdentifier == AppGroup.identifier)
        #expect(!AppGroup.identifier.hasPrefix("$("))
        let task = try #require(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        let groups = try #require(value as? [String])
        #expect(groups == [AppGroup.identifier])
    }
}
