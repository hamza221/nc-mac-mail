// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// WS-35's live acceptance: an offline edit reaches what web Contacts reads, with every
/// property it did not touch intact; a favourite toggled here is PROPPATCHed, and one toggled
/// on the server comes back through the per-pass listing although no token moved (ADR-0092).
///
/// ```
/// TEST_RUNNER_NCMAIL_LIVE_CONTACTS=http://localhost TEST_RUNNER_NCMAIL_LIVE_USER=admin \
///   TEST_RUNNER_NCMAIL_LIVE_PASSWORD=admin \
///   xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/ContactsLiveTests test
/// ```
///
/// Cards go into the login's own "Contacts" book, so web Contacts shows them; they are
/// deleted at the end unless `TEST_RUNNER_NCMAIL_LIVE_KEEP=1`.
@Suite("Contacts against a live server", .serialized)
@MainActor
struct ContactsLiveTests {
    nonisolated static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_CONTACTS"]

    private struct Live {
        let store: MailStore
        let dav: DAVClient
        let mail: MailClient
        let loginId: Int64
        let queue: MutationQueue
        let configuration: MutationQueueConfiguration
        let sync: ContactsSync
        let book: AddressBookRecord
        let folder: URL

        var actions: ContactsActions { ContactsActions(loginId: loginId, store: store, queue: queue) }

        func drain() async throws {
            let accountId = try await queue.queueAccountId(loginId: loginId)
            await OperationDrainer(store: store, client: mail, accountId: accountId, configuration: configuration)
                .drain()
        }
    }

    private func live() async throws -> Live {
        let environment = ProcessInfo.processInfo.environment
        let server = try #require(environment["NCMAIL_LIVE_CONTACTS"].flatMap(URL.init(string:)))
        let credentials = BasicCredentials(
            loginName: try #require(environment["NCMAIL_LIVE_USER"]),
            appPassword: try #require(environment["NCMAIL_LIVE_PASSWORD"]))
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ws35-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try MailStore(url: folder.appending(path: "mirror.sqlite"))
        let dav = DAVClient(server: server, credentials: credentials)
        let mail = MailClient(server: server, credentials: credentials, clientVersion: "ws35-live")
        let identity = ServerIdentity(serverURL: server, loginName: credentials.loginName)
        _ = try await MirrorCoordinator.discoverAccounts(store: store, client: mail, identity: identity)
        let loginId = try #require(try await store.ensureLogin(identity).id)
        let configuration = MutationQueueConfiguration(dav: ContactWriteHandler(store: store, client: dav))
        let queue = MutationQueue(store: store, configuration: configuration)
        let sync = ContactsSync(
            store: store, client: dav, loginId: loginId,
            pendingWrites: { try await queue.pendingDAVWrites(loginId: loginId) })
        _ = try await sync.runPass()
        let book = try #require(
            try await store.addressBooks(loginId: loginId).first {
                $0.sharedBy == nil && !$0.isReadOnly && $0.url.hasSuffix("/contacts/")
            })
        return Live(
            store: store, dav: dav, mail: mail, loginId: loginId, queue: queue, configuration: configuration,
            sync: sync, book: book, folder: folder)
    }

    /// A card as another client wrote it, PUT straight onto the server.
    private func seed(_ live: Live, uid: String) async throws -> (href: String, url: URL) {
        let href = try #require(ContactCardActions.newHref(bookURL: live.book.url, uid: uid))
        let url = live.dav.resolve(href: href)
        let card = """
            BEGIN:VCARD\r
            VERSION:3.0\r
            PRODID:-//WS35 Live//Other Client//EN\r
            UID:\(uid)\r
            FN:WS35 Live Person\r
            N:Person;WS35 Live;;;\r
            item1.EMAIL;TYPE=INTERNET,WORK:\(uid)@example.org\r
            item1.X-ABLabel:_$!<Work>!$_\r
            X-WS35-UNKNOWN;X-PARAM="kept, as is":opaque\\;value\r
            GEO:41.56;-72.95\r
            END:VCARD\r

            """
        try await live.dav.put(url, data: Data(card.utf8), contentType: "text/vcard; charset=utf-8")
        _ = try await live.sync.runPass()
        return (href, url)
    }

    private func cleanUp(_ live: Live, _ url: URL) async {
        if ProcessInfo.processInfo.environment["NCMAIL_LIVE_KEEP"] != "1" {
            try? await live.dav.delete(url)
        }
        try? FileManager.default.removeItem(at: live.folder)
    }

    private func measure(_ line: String) {
        FileHandle.standardError.write(Data("  [measured] live WS-35: \(line)\n".utf8))
    }

    @Test(.enabled(if: serverEnvironment != nil), .timeLimit(.minutes(3)))
    func offlineEditReachesWebContactsWithOtherPropertiesIntact() async throws {
        let live = try await live()
        let uid = "ws35-live-\(UUID().uuidString)"
        let (href, url) = try await seed(live, uid: uid)
        defer { Task { await cleanUp(live, url) } }
        let bookId = try #require(live.book.id)
        let record = try #require(try await live.store.contacts(addressBookId: bookId).first { $0.href == href })
        let id = try #require(record.id)

        // Offline: no drainer. The edit is local at once and waits in the queue.
        var draft = ContactDraft(card: try #require(try VCardParser.parse(record.vcard).first))
        draft.title = "Edited offline"
        draft.fields.append(.init(kind: .phone, type: "CELL", value: "+1 555 0135"))
        draft.categories = ["WS35 Live"]
        let started = ContinuousClock.now
        try await live.actions.save(draft, over: record, in: live.book)
        let queued = ContinuousClock.now - started
        #expect(try await live.store.contact(id: id)?.vcard.contains("TITLE:Edited offline") == true)
        #expect(try await live.queue.pendingDAVWrites(loginId: live.loginId).count == 1)

        // Online: the drainer sends it; read back what web Contacts reads.
        let drainStart = ContinuousClock.now
        try await live.drain()
        let drained = ContinuousClock.now - drainStart
        let bookURL = try #require(URL(string: live.book.url))
        let onServer = try #require(try await live.dav.addressbookMultiget(bookURL, hrefs: [href]).first?.addressData)
        measure("offline edit queued in \(queued), drained in \(drained)")

        #expect(onServer.contains("TITLE:Edited offline"))
        #expect(onServer.contains("+1 555 0135"))
        #expect(onServer.contains("CATEGORIES:WS35 Live"))
        // The other client's lines, untouched (unfolded comparison: sabre may re-fold).
        let unfolded = onServer.replacingOccurrences(of: "\r\n ", with: "")
        for line in [
            "PRODID:-//WS35 Live//Other Client//EN", "item1.EMAIL;TYPE=INTERNET,WORK:\(uid)@example.org",
            "item1.X-ABLabel:_$!<Work>!$_", "X-WS35-UNKNOWN;X-PARAM=\"kept, as is\":opaque\\;value",
            "GEO:41.56;-72.95",
        ] {
            #expect(unfolded.contains(line), "\(line) did not survive")
        }
        #expect(try await live.queue.pendingDAVWrites(loginId: live.loginId).isEmpty)
    }

    @Test(.enabled(if: serverEnvironment != nil), .timeLimit(.minutes(3)))
    func favouriteRoundTripsBothWays() async throws {
        let live = try await live()
        let uid = "ws35-fav-\(UUID().uuidString)"
        let (href, url) = try await seed(live, uid: uid)
        defer { Task { await cleanUp(live, url) } }
        let bookId = try #require(live.book.id)
        let record = try #require(try await live.store.contacts(addressBookId: bookId).first { $0.href == href })
        let bookURL = try #require(URL(string: live.book.url))
        func token() async throws -> String? {
            try await live.dav.propfind(bookURL, depth: .zero, properties: [.syncToken]).first?.syncToken
        }
        func serverFavorite() async throws -> Bool? {
            try await live.dav.propfind(url, depth: .zero, properties: [.getetag, .favorite]).first?.isFavorite
        }
        func etag() async throws -> String? {
            try await live.dav.propfind(url, depth: .zero, properties: [.getetag]).first?.etag
        }

        // Here → server: queued, then PROPPATCHed by the drainer.
        let tokenBefore = try await token()
        let etagBefore = try await etag()
        try await live.actions.setFavorite(true, contact: record, in: live.book)
        let id = try #require(record.id)
        #expect(try await live.store.contact(id: id)?.isFavorite == true)
        try await live.drain()
        #expect(try await serverFavorite() == true)
        let tokenAfter = try await token()
        let etagAfter = try await etag()
        measure(
            "favourite PROPPATCH: sync-token moved \(tokenBefore != tokenAfter), ETag moved \(etagBefore != etagAfter)")
        #expect(tokenBefore == tokenAfter && etagBefore == etagAfter)

        // Server → here, as web Contacts would unstar it: no token moves, the listing sees it.
        try await live.dav.setFavorite(url, false)
        let passStart = ContinuousClock.now
        let report = try await live.sync.runPass()
        let pass = ContinuousClock.now - passStart
        let books = try await live.store.addressBooks(loginId: live.loginId).filter(\.isEnabled).count
        measure(
            "unstar mirrored by one pass in \(pass): \(report.favoriteListings) favourite listings for \(books) books, "
                + "\(report.favoritesChanged) changed, \(report.booksSynced) books re-synced")
        #expect(try await live.store.contact(id: id)?.isFavorite == false)
        #expect(report.favoritesChanged >= 1)
    }

    /// The Contacts app's social-avatar route through the queue. Whether a picture arrives
    /// depends on the server reaching Gravatar, so that part is measured, not asserted.
    @Test(.enabled(if: serverEnvironment != nil), .timeLimit(.minutes(3)))
    func socialAvatarRequestIsAccepted() async throws {
        let live = try await live()
        let uid = "ws35-social-\(UUID().uuidString)"
        let (href, url) = try await seed(live, uid: uid)
        defer { Task { await cleanUp(live, url) } }
        let bookId = try #require(live.book.id)
        var record = try #require(try await live.store.contacts(addressBookId: bookId).first { $0.href == href })
        // Gravatar keys on the address; this one has a public Gravatar (as the recorder uses).
        var draft = ContactDraft(card: try #require(try VCardParser.parse(record.vcard).first))
        draft.fields.append(.init(kind: .email, type: "HOME", value: "beau@dentedreality.com.au"))
        try await live.actions.save(draft, over: record, in: live.book)
        try await live.drain()
        _ = try await live.sync.runPass()
        record = try #require(try await live.store.contacts(addressBookId: bookId).first { $0.href == href })

        try await live.actions.fetchSocialAvatar(network: "gravatar", contact: record, in: live.book)
        try await live.drain()
        #expect(try await live.queue.pendingDAVWrites(loginId: live.loginId).isEmpty)
        _ = try await live.sync.runPass()
        let after = try await live.store.contacts(addressBookId: bookId).first { $0.href == href }
        measure(
            "social avatar request accepted; PHOTO present after next pass: \(after?.vcard.contains("PHOTO") == true)")
    }
}
