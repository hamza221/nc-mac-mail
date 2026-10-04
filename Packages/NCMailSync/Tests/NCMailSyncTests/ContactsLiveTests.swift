// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NCMailSync

/// WS-24's live acceptance, against a real Nextcloud:
///
/// ```
/// NCMAIL_LIVE_DAV=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --build-system native --filter ContactsLiveTests
/// ```
///
/// Each test creates its own scratch address book and deletes it at the end (ADR-0080).
/// The cards are generated here and PUT to the server, so what the mirror reads back is the
/// server's own serialisation — no hand-written fixture is involved.
@Suite("Contacts mirror against a live server", .serialized)
struct ContactsLiveTests {
    static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_DAV"]

    private struct Live {
        let server: URL
        let user: String
        let password: String
        let dav: DAVClient

        init() throws {
            let environment = ProcessInfo.processInfo.environment
            server = try #require(environment["NCMAIL_LIVE_DAV"].flatMap(URL.init(string:)))
            user = try #require(environment["NCMAIL_LIVE_USER"])
            password = try #require(environment["NCMAIL_LIVE_PASSWORD"])
            dav = DAVClient(server: server, credentials: BasicCredentials(loginName: user, appPassword: password))
        }

        var credentials: BasicCredentials { BasicCredentials(loginName: user, appPassword: password) }

        func scratchBook(_ name: String) async throws -> URL {
            let home = try #require(try await dav.discoverHomeSets().addressbookHome)
            let url = home.appending(path: name, directoryHint: .isDirectory)
            try? await dav.delete(url)
            try await dav.mkcolExtended(
                url, resourceTypes: [.addressbook], properties: [DAVProposedProperty(.displayname, name)])
            return url
        }

        func store() throws -> (MailStore, URL) {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "ncmail-contacts-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (try MailStore(url: folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory)), folder)
        }
    }

    // MARK: - 2,000 contacts in under 60 s

    @Test(.enabled(if: serverEnvironment != nil), .timeLimit(.minutes(10)))
    func twoThousandContactsMirrorInUnderAMinute() async throws {
        let live = try Live()
        let book = try await live.scratchBook("ws24-live-2000")
        let (store, folder) = try live.store()
        defer { try? FileManager.default.removeItem(at: folder) }

        let count = 2000
        let seedStarted = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < count else { return }
                let index = next
                next += 1
                group.addTask {
                    let card = SyntheticCards.card(index)
                    try await live.dav.put(
                        book.appending(path: "ws24-\(index).vcf"),
                        data: Data(card.utf8),
                        contentType: "text/vcard; charset=utf-8")
                }
            }
            for _ in 0..<16 { add() }
            while try await group.next() != nil { add() }
        }
        let seedElapsed = ContinuousClock.now - seedStarted

        let login = try await store.ensureLogin(ServerIdentity(serverURL: live.server, loginName: live.user))
        let loginId = try #require(login.id)
        let sync = ContactsSync(store: store, client: live.dav, loginId: loginId, pendingWrites: { [] })

        let started = ContinuousClock.now
        let report = try await sync.runPass()
        let elapsed = ContinuousClock.now - started

        let againStarted = ContinuousClock.now
        let again = try await sync.runPass()
        let againElapsed = ContinuousClock.now - againStarted

        let row = try #require(try await store.addressBooks(loginId: loginId).first { $0.url == book.absoluteString })
        let mirrored = try await store.contacts(addressBookId: try #require(row.id))
        let withPhoto = mirrored.filter { $0.vcard.contains("PHOTO") }
        let photoContactId = try #require(withPhoto.first?.id)
        let avatarEmail = try #require(try await store.contactEmails(contactId: photoContactId).first?.email)
        let avatar = try await store.avatar(for: avatarEmail)

        try await live.dav.delete(book)

        Issue.record(
            """
            live contacts mirror: \(count) cards seeded in \(seedElapsed) (16 PUTs in flight); \
            first pass \(elapsed) for \(report.booksListed) books, \(report.cardsWritten) cards written, \
            \(report.multigetRequests) multigets; second pass \(againElapsed), \(again.booksSynced) books visited, \
            \(again.cardsWritten) cards written
            """
        )
        #expect(mirrored.count == count)
        #expect(elapsed < .seconds(60))
        #expect(report.multigetRequests >= count / ContactsSync.multigetBatchSize)
        #expect(again.cardsWritten < 10)  // only token-less books are re-listed; nothing changed
        #expect(avatar?.data != nil && avatar?.isExternal == false)
    }

    // MARK: - Offline edit → reconnect → on the server, merged with a web edit

    @Test(.enabled(if: serverEnvironment != nil), .timeLimit(.minutes(5)))
    func offlineEditReachesTheServerOnReconnectAndMergesAWebEdit() async throws {
        let live = try Live()
        let book = try await live.scratchBook("ws24-live-edit")
        let cardURL = book.appending(path: "ws24-live-edit.vcf")
        try await live.dav.put(
            cardURL,
            data: Data(
                "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ws24-live-edit\r\nFN:WS24 Live Edit\r\nN:Edit;WS24;;;\r\nEMAIL;TYPE=WORK:before@example.org\r\nTEL;TYPE=CELL:+1 555 0100\r\nNOTE:before\r\nEND:VCARD\r\n"
                    .utf8),
            contentType: "text/vcard; charset=utf-8")
        let (store, folder) = try live.store()
        defer { try? FileManager.default.removeItem(at: folder) }

        // The queue stores login-scoped rows under the login's first mail account.
        let mail = MailClient(server: live.server, credentials: live.credentials, clientVersion: "ws24-live")
        let identity = ServerIdentity(serverURL: live.server, loginName: live.user)
        _ = try await MirrorCoordinator.discoverAccounts(store: store, client: mail, identity: identity)
        let loginId = try #require(try await store.ensureLogin(identity).id)

        let conflicts = ContactConflictLog()
        let handler = ContactWriteHandler(store: store, client: live.dav, conflicts: conflicts)
        let configuration = MutationQueueConfiguration(dav: handler)
        let queue = MutationQueue(store: store, configuration: configuration)
        let sync = ContactsSync(
            store: store, client: live.dav, loginId: loginId,
            pendingWrites: { try await queue.pendingDAVWrites(loginId: loginId) })
        _ = try await sync.runPass()
        let bookRow = try #require(
            try await store.addressBooks(loginId: loginId).first { $0.url == book.absoluteString })
        let bookRowId = try #require(bookRow.id)
        let mirrored = try #require(try await store.contacts(addressBookId: bookRowId).first)
        let mirroredId = try #require(mirrored.id)

        // Offline: the edit lands locally and in the queue, and nothing is sent.
        await sync.apply(conditions: MirrorConditions(isOffline: true))
        var card = try #require(try VCardParser.parse(mirrored.vcard).first)
        card.setProperty(
            "EMAIL", to: "offline@example.org", parameters: [DirectoryParameter(name: "TYPE", values: ["WORK"])])
        card.setProperty("NOTE", to: "edited offline")
        let payload = ContactWriteHandler.putPayload(
            loginId: loginId, addressBookId: try #require(bookRow.id), existing: mirrored, card: card)
        try await queue.perform(.contactPut(payload), loginId: loginId)
        let local = try #require(try await store.contact(id: mirroredId))
        #expect(local.vcard.contains("offline@example.org"))
        #expect(await sync.syncNow() == ContactsSyncReport())

        // Meanwhile the web edits the phone number.
        try await live.dav.put(
            cardURL,
            data: Data(
                "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ws24-live-edit\r\nFN:WS24 Live Edit\r\nN:Edit;WS24;;;\r\nEMAIL;TYPE=WORK:before@example.org\r\nTEL;TYPE=CELL:+1 555 0199\r\nNOTE:before\r\nEND:VCARD\r\n"
                    .utf8),
            contentType: "text/vcard; charset=utf-8")

        // Reconnect: the drainer sends, meets the 412, reapplies EMAIL and NOTE onto the web
        // copy and lands it.
        let accountId = try await queue.queueAccountId(loginId: loginId)
        let drainer = OperationDrainer(store: store, client: mail, accountId: accountId, configuration: configuration)
        let started = ContinuousClock.now
        await drainer.drain()
        let drainElapsed = ContinuousClock.now - started
        await sync.apply(conditions: MirrorConditions())
        _ = try await sync.runPass()

        let onServer = try #require(
            try await live.dav.addressbookMultiget(book, hrefs: [cardURL.path(percentEncoded: true)]).first?.addressData
        )
        let queuedAfter = try await queue.pendingDAVWrites(loginId: loginId)
        let finalLocal = try #require(try await store.contacts(addressBookId: bookRowId).first)
        // NCMAIL_LIVE_KEEP=1 leaves the book for a look in web Contacts; delete it after.
        if ProcessInfo.processInfo.environment["NCMAIL_LIVE_KEEP"] != "1" {
            try await live.dav.delete(book)
        }

        Issue.record(
            "live offline edit: drained in \(drainElapsed); conflict log \(await conflicts.entries.map(\.outcome))")
        #expect(onServer.contains("offline@example.org"))
        #expect(onServer.contains("edited offline"))
        #expect(onServer.contains("+1 555 0199"))
        #expect(queuedAfter.isEmpty)
        #expect(finalLocal.vcard == onServer)
        #expect(await conflicts.entries.isEmpty)
    }
}

/// Deterministic, varied cards: one to three addresses, phones, organisations, birthdays,
/// postal addresses, notes with escapes, a photo on every 25th, groups every 100th.
enum SyntheticCards {
    private static let given = [
        "Ada", "Bruno", "Chloé", "Dmitri", "Eun-ji", "Farah", "Gustav", "Hana", "Ignacio", "Jun",
    ]
    private static let family = [
        "Okafor", "Müller", "Nakamura", "Santos", "O'Brien", "Kowalski", "Haddad", "Lindqvist",
    ]
    private static let organizations = ["Acme", "Globex; R&D", "Initech", "Umbrella, Inc.", "Hooli"]
    /// A 1×1 PNG: the smallest photo that is still a real image.
    private static let png =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    static func card(_ index: Int) -> String {
        let first = given[index % given.count]
        let last = family[(index / given.count) % family.count]
        var lines = [
            "BEGIN:VCARD", "VERSION:3.0", "UID:ws24-\(index)",
            "FN:\(first) \(last) \(index)", "N:\(last);\(first);;;",
        ]
        if index % 100 == 0 {
            lines += ["X-ADDRESSBOOKSERVER-KIND:group"]
            lines += (1...5).map { "X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:ws24-\(index + $0)" }
        }
        for address in 0..<(1 + index % 3) {
            let type = ["WORK", "HOME", "OTHER"][address]
            lines.append("EMAIL;TYPE=\(type):\(first.lowercased())\(index).\(address)@example.org")
        }
        if index % 2 == 0 { lines.append("TEL;TYPE=CELL:+1 555 \(String(format: "%04d", index))") }
        if index % 3 == 0 {
            lines.append(
                "ORG:\(organizations[index % organizations.count].replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,"))"
            )
        }
        if index % 4 == 0 { lines.append("BDAY:19\(70 + index % 30)-0\(1 + index % 9)-1\(index % 10)") }
        if index % 5 == 0 { lines.append("ADR;TYPE=HOME:;;\(index) Main St;Springfield;;\(10000 + index);Nowhere") }
        if index % 7 == 0 { lines.append("NOTE:Line one\\nLine two\\, with a comma") }
        if index % 25 == 0 { lines.append("PHOTO;ENCODING=b;TYPE=PNG:\(png)") }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
