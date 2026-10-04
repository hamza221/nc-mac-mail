// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NCMailSync

/// Every Files action against a live server, timed. Off by default: it opens sockets and
/// writes into the account's Files (a scratch image, and whatever save-to-Files creates —
/// all deleted again).
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter FilesLive
/// ```
@Suite("Files against a live server", .serialized)
struct FilesLiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR"]

    /// A 1×1 PNG.
    private static let png = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

    @Test(.enabled(if: FilesLiveTests.serverEnvironment != nil))
    func everyActionAgainstTheServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_MIRROR"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw MirrorLiveMeasurementTests.LiveError.missingEnvironment }

        let credentials = BasicCredentials(loginName: user, appPassword: password)
        let store = try MailStore.inMemory()
        let dav = DAVClient(server: server, credentials: credentials)
        let client = MailClient(server: server, credentials: credentials)
        let loginId = try #require(try await store.ensureLogin(ServerIdentity(serverURL: server, loginName: user)).id)
        let sync = FilesListingSync(store: store, dav: dav, client: client, loginId: loginId)
        let clock = ContinuousClock()

        // A scratch image to list, share and embed.
        let name = "ws33-live-\(UUID().uuidString.prefix(8)).png"
        let principal = try await dav.currentUserPrincipal()
        let userId = try #require(principal.path(percentEncoded: false).split(separator: "/").last.map(String.init))
        let root = dav.davRoot.appending(path: "files/\(userId)/", directoryHint: .isDirectory)
        try await dav.put(root.appending(path: name), data: try #require(Self.png), contentType: "image/png")

        // Listing.
        var started = clock.now
        await sync.request(path: "/", force: true)
        await sync.settle()
        let listingTime = clock.now - started
        let listed = try #require(
            try await store.filesListing(path: "/", loginId: loginId).map(FilesListingState.init(record:))?.entries)
        let image = try #require(listed.first { $0.name == name })
        #expect(image.mime == "image/png" && image.isEmbeddableImage)
        measured("root listing \(listed.count) entries in \(listingTime)")

        // Share link.
        started = clock.now
        #expect(await sync.createShareLink(path: image.path).isSuccess)
        let shareTime = clock.now - started
        let shareRow = try #require(
            try await store.serverResult(kind: FilesListingSync.shareLinkKind, key: image.path, loginId: loginId))
        let link = try #require(FilesListingSync.shareLinkURL(in: shareRow))
        #expect(link.path.contains("/s/"))
        measured("share link in \(shareTime)")

        // Insert image.
        started = clock.now
        #expect(await sync.stageImage(image).isSuccess)
        let imageTime = clock.now - started
        let imageRow = try #require(
            try await store.serverResult(kind: FilesListingSync.imageKind, key: image.path, loginId: loginId))
        let staged = try #require(FilesListingSync.stagedImageURL(in: imageRow))
        #expect(try Data(contentsOf: staged) == Self.png)
        try? FileManager.default.removeItem(at: staged)
        measured("image staged in \(imageTime)")

        // Save an attachment and a whole message to Files, through the routes the queued
        // `saveToFiles` kind drains to, then find them in a fresh listing.
        let account = try #require(try await client.get(.accounts).first?.value)
        let inbox = try #require(
            try await client.get(.mailboxes(accountId: account.id)).mailboxes.first { $0.specialRole == "inbox" })
        let messages = try await client.get(.messages(mailboxId: inbox.id)).map(\.value)
        let withAttachment = try #require(messages.first { !$0.attachments.isEmpty })
        let attachment = try #require(withAttachment.attachments.first)
        _ = try await client.post(
            .saveAttachmentToFiles(messageId: withAttachment.id, attachmentId: attachment.id),
            body: TargetPathRequest(targetPath: "/"))
        _ = try await client.post(
            .saveMessageToFiles(messageId: withAttachment.id), body: TargetPathRequest(targetPath: "/"))

        await sync.request(path: "/", force: true)
        await sync.settle()
        let after = try #require(
            try await store.filesListing(path: "/", loginId: loginId).map(FilesListingState.init(record:))?.entries)
        let before = Set(listed.map(\.path))
        let created = after.filter { !before.contains($0.path) }
        let stem = ((attachment.fileName ?? "") as NSString).deletingPathExtension
        #expect(created.contains { !stem.isEmpty && $0.name.hasPrefix(stem) })
        #expect(created.contains { $0.name.hasSuffix(".eml") })
        measured("save-to-Files created \(created.map(\.name))")
        for entry in created {
            try? await dav.delete(FilesListingSync.url(of: entry.path, under: root, isFolder: false))
        }
        try await dav.delete(root.appending(path: name))
    }

    /// A count or a duration, to stderr, where the brief's numbers are read from.
    private func measured(_ text: String) {
        FileHandle.standardError.write(Data(("  [measured] files live: " + text + "\n").utf8))
    }
}
