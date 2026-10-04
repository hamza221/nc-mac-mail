// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// WS-36's live acceptance, in one address book's life: created offline, 500 cards imported
/// offline into it, all of it drained on reconnect (measured); two contacts merged; renamed,
/// disabled, shared read-only with a second user (checked from that user's side); exported
/// from the mirror and compared with the server; deleted.
///
/// ```
/// TEST_RUNNER_NCMAIL_LIVE_CONTACTS=http://localhost TEST_RUNNER_NCMAIL_LIVE_USER=admin \
///   TEST_RUNNER_NCMAIL_LIVE_PASSWORD=admin TEST_RUNNER_NCMAIL_LIVE_SHARE_USER=alice \
///   TEST_RUNNER_NCMAIL_LIVE_SHARE_PASSWORD=alice \
///   xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/AddressBooksLiveTests test
/// ```
///
/// The book is deleted at the end unless `TEST_RUNNER_NCMAIL_LIVE_KEEP=1`.
@Suite("Address books against a live server", .serialized)
@MainActor
struct AddressBooksLiveTests {
    nonisolated static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_CONTACTS"]
    private static let enabledName = DAVQualifiedName(DAVQualifiedName.owncloud, "enabled")
    private static let readOnlyName = DAVQualifiedName(DAVQualifiedName.owncloud, "read-only")

    private func measure(_ line: String) {
        FileHandle.standardError.write(Data("  [measured] live WS-36: \(line)\n".utf8))
    }

    private static func generatedFile(count: Int, run: String) -> Data {
        var text = ""
        for index in 0..<count {
            // Alternate 3.0 and 4.0, as a real export from several clients would.
            let version = index.isMultiple(of: 2) ? "3.0" : "4.0"
            text += "BEGIN:VCARD\r\nVERSION:\(version)\r\nUID:ws36-\(run)-\(index)\r\n"
            text += "FN:WS36 Person \(index)\r\nN:Person \(index);WS36;;;\r\n"
            text += "EMAIL;TYPE=work:person\(index)@ws36.example.org\r\nTEL;TYPE=cell:+1 555 \(1000 + index)\r\n"
            text += "X-WS36-RUN:\(run)\r\nEND:VCARD\r\n"
        }
        return Data(text.utf8)
    }

    @Test(.enabled(if: serverEnvironment != nil), .timeLimit(.minutes(10)))
    func addressBookLifeOfflineImportMergeShareExportDelete() async throws {
        let environment = ProcessInfo.processInfo.environment
        let server = try #require(environment["NCMAIL_LIVE_CONTACTS"].flatMap(URL.init(string:)))
        let user = try #require(environment["NCMAIL_LIVE_USER"])
        let credentials = BasicCredentials(
            loginName: user, appPassword: try #require(environment["NCMAIL_LIVE_PASSWORD"]))
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ws36-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MailStore(url: folder.appending(path: "mirror.sqlite"))
        let dav = DAVClient(server: server, credentials: credentials)
        let mail = MailClient(server: server, credentials: credentials, clientVersion: "ws36-live")
        let identity = ServerIdentity(serverURL: server, loginName: user)
        _ = try await MirrorCoordinator.discoverAccounts(store: store, client: mail, identity: identity)
        let loginId = try #require(try await store.ensureLogin(identity).id)
        let configuration = MutationQueueConfiguration(dav: ContactWriteHandler(store: store, client: dav))
        let queue = MutationQueue(store: store, configuration: configuration)
        let sync = ContactsSync(
            store: store, client: dav, loginId: loginId,
            pendingWrites: { try await queue.pendingDAVWrites(loginId: loginId) })
        _ = try await sync.runPass()
        let actions = AddressBookActions(loginId: loginId, store: store, queue: queue)
        let accountId = try await queue.queueAccountId(loginId: loginId)
        func drain() async throws -> Int {
            var rounds = 0
            while try await !queue.pendingDAVWrites(loginId: loginId).isEmpty {
                await OperationDrainer(store: store, client: mail, accountId: accountId, configuration: configuration)
                    .drain()
                rounds += 1
                if rounds > 50 { break }
            }
            return rounds
        }

        let run = String(UUID().uuidString.prefix(8)).lowercased()
        let name = "WS36 Live \(run)"

        // Offline: create the book and import 500 cards into it. Nothing has been sent.
        let href = try await actions.create(
            name: name, books: try await store.addressBooks(loginId: loginId),
            fallbackHome: AddressBookActions.fallbackHome(serverURL: server, userId: user))
        let bookURL = dav.resolve(href: href)
        defer {
            if environment["NCMAIL_LIVE_KEEP"] != "1" {
                Task { try? await dav.delete(bookURL) }
            }
        }
        var book = try #require(try await store.addressBooks(loginId: loginId).first { $0.url.hasSuffix(href) })
        let plan = try VCardImportPlan.make(
            data: Self.generatedFile(count: 500, run: run), bookURL: book.url, existing: [])
        let queueStart = ContinuousClock.now
        try await actions.importCards(plan, into: book) { _ in }
        let queued = ContinuousClock.now - queueStart
        let bookId = try #require(book.id)
        #expect(try await store.contacts(addressBookId: bookId).count == 500)
        #expect(try await queue.pendingDAVWrites(loginId: loginId).count == 501)

        // Reconnect: the drainer sends the book and every card.
        let drainStart = ContinuousClock.now
        let rounds = try await drain()
        let drained = ContinuousClock.now - drainStart
        let onServer = try await dav.propfind(bookURL, depth: .one, properties: [.getetag])
            .filter { $0.href.hasSuffix(".vcf") }
        measure(
            "500-card import queued offline in \(queued); drained (book + 500 PUTs) in \(drained) over \(rounds) drain call(s)"
        )
        #expect(onServer.count == 500)
        #expect(try await queue.pendingDAVWrites(loginId: loginId).isEmpty)
        let bookProps = try #require(try await dav.propfind(bookURL, depth: .zero, properties: [.displayname]).first)
        #expect(bookProps.displayName == name)

        // A pass brings the server's ETags into the mirror.
        _ = try await sync.runPass()
        book = try #require(try await store.addressBooks(loginId: loginId).first { $0.id == bookId })

        // Merge two of them.
        var records = try await store.contacts(addressBookId: bookId)
        let kept = try #require(records.first { $0.uid == "ws36-\(run)-0" })
        let other = try #require(records.first { $0.uid == "ws36-\(run)-1" })
        var mergePlan = ContactMergePlan(
            kept: try #require(try VCardParser.parse(kept.vcard).first),
            other: try #require(try VCardParser.parse(other.vcard).first))
        if let index = mergePlan.singles.firstIndex(where: { $0.name == "FN" }) {
            mergePlan.singles[index].pick = .other
        }
        try await actions.merge(mergePlan, kept: kept, other: other, books: [book])
        _ = try await drain()
        let afterMerge = try await dav.propfind(bookURL, depth: .one, properties: [.getetag])
            .filter { $0.href.hasSuffix(".vcf") }
        #expect(afterMerge.count == 499)
        let mergedText = try #require(
            try await dav.addressbookMultiget(bookURL, hrefs: [kept.href]).first?.addressData)
        let unfolded = mergedText.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("FN:WS36 Person 1"))
        #expect(unfolded.contains("person0@ws36.example.org") && unfolded.contains("person1@ws36.example.org"))
        #expect(unfolded.contains("X-WS36-RUN:\(run)"))
        measure(
            "merge: server card has both addresses and both numbers: \(unfolded.contains("1000") && unfolded.contains("1001"))"
        )

        // Rename, disable, share read-only.
        try await actions.rename(book, to: name + " renamed")
        book = try #require(try await store.addressBooks(loginId: loginId).first { $0.id == bookId })
        try await actions.setEnabled(false, book: book)
        book = try #require(try await store.addressBooks(loginId: loginId).first { $0.id == bookId })
        let shareUser = environment["NCMAIL_LIVE_SHARE_USER"]
        if let shareUser {
            try await actions.share(
                book, with: ShareeSuggestion(shareWith: shareUser, type: "user", displayName: shareUser), readOnly: true
            )
        }
        _ = try await drain()
        let props = try #require(
            try await dav.propfind(bookURL, depth: .zero, properties: [.displayname, Self.enabledName]).first)
        #expect(props.displayName == name + " renamed")
        #expect(props.property(Self.enabledName)?.text == "0")

        if let shareUser, let sharePassword = environment["NCMAIL_LIVE_SHARE_PASSWORD"] {
            let alice = DAVClient(
                server: server, credentials: BasicCredentials(loginName: shareUser, appPassword: sharePassword))
            let home = alice.davRoot.appending(path: "addressbooks/users/\(shareUser)", directoryHint: .isDirectory)
            let books = try await alice.propfind(
                home, depth: .one, properties: [.displayname, .resourcetype, Self.readOnlyName])
            let seen = books.first { $0.isAddressbook && $0.displayName?.hasPrefix(name) == true }
            measure(
                "share seen by \(shareUser): \(seen?.href ?? "none"), oc:read-only=\(seen?.property(Self.readOnlyName)?.text ?? "-")"
            )
            #expect(seen != nil)
            #expect(seen?.property(Self.readOnlyName)?.text == "1")
        }

        // Export from the mirror: the same cards the server holds.
        _ = try await sync.runPass()
        records = try await store.contacts(addressBookId: bookId)
        let exportStart = ContinuousClock.now
        let exported = VCardExport.data(records)
        let exportTime = ContinuousClock.now - exportStart
        let cards = try VCardParser.parse(exported)
        measure("export of \(records.count) cards from the mirror: \(exported.count) bytes in \(exportTime)")
        #expect(cards.count == 499)
        #expect(Set(cards.compactMap(\.uid)) == Set(records.compactMap(\.uid)))

        // Delete.
        try await actions.delete(book)
        #expect(try await store.addressBooks(loginId: loginId).allSatisfy { $0.id != bookId })
        _ = try await drain()
        await #expect(throws: (any Error).self) {
            try await dav.propfind(bookURL, depth: .zero, properties: [.displayname])
        }
    }
}
