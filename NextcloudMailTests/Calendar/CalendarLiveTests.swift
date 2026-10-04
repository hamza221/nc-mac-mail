// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// WS-34's live acceptance, through `MessageCalendarModel` and the queue — the objects the
/// message pane uses — with the drainer standing in for reconnecting.
///
/// The mail is seeded beforehand, because a test host cannot reach the server's container:
/// a same-server organiser (`alice`) creates an event inviting the login's principal address,
/// which Nextcloud's scheduling delivers into the attendee's default calendar; the iMIP mail
/// that would carry it is APPENDed to the inbox through the server's own IMAP client (outgoing
/// SMTP is refusing with 452 on the dev server, and the principal address is not the mail
/// account's address anyway), with an alias for the principal address so the card recognises
/// the attendee; a flight confirmation with schema.org JSON-LD is APPENDed the same way for
/// the itinerary extractor. ADR-0093's Context spells the seeding out; the APPEND is the one
/// in `Scripts/record-fixtures.sh`'s WS-34 section.
///
/// ```
/// TEST_RUNNER_NCMAIL_LIVE_CALENDAR=http://localhost TEST_RUNNER_NCMAIL_LIVE_USER=admin \
///   TEST_RUNNER_NCMAIL_LIVE_PASSWORD=admin TEST_RUNNER_NCMAIL_LIVE_WS34_TOKEN=<token> \
///   TEST_RUNNER_NCMAIL_LIVE_WS34_UID=<event uid> TEST_RUNNER_NCMAIL_LIVE_WS34_ORGANIZER=alice \
///   TEST_RUNNER_NCMAIL_LIVE_WS34_ORGANIZER_PASSWORD=alice \
///   xcodebuild test -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/CalendarLiveTests
/// ```
@MainActor
@Suite("Calendar against a live server", .serialized)
struct CalendarLiveTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated static var hasLiveServer: Bool {
        environment["NCMAIL_LIVE_CALENDAR"] != nil && environment["NCMAIL_LIVE_WS34_TOKEN"] != nil
    }

    enum LiveError: Error { case missingEnvironment, notFound(String) }

    struct Live {
        let store: MailStore
        let client: MailClient
        let dav: DAVClient
        let identity: ServerIdentity
        let loginId: Int64
        let account: AccountRecord
        let inbox: MailboxRecord
        let drainer: OperationDrainer
        let queue: MutationQueue
        let model: MessageCalendarModel
        let calendars: [CalendarRecord]
    }

    private static func live() async throws -> Live {
        guard
            let raw = environment["NCMAIL_LIVE_CALENDAR"], let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"], let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }
        let store = try MailStore.inMemory()
        let credentials = BasicCredentials(loginName: user, appPassword: password)
        let client = MailClient(server: server, credentials: credentials, clientVersion: "ws34-live-test")
        let dav = DAVClient(server: server, credentials: credentials)
        let identity = ServerIdentity(serverURL: server.absoluteString, loginName: user)
        let loginId = try #require(try await store.ensureLogin(identity).id)
        let accounts = try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity)
        let account = try #require(accounts.first)
        // Aliases arrive with the state mirror in the app; here, straight from the list.
        for remote in try await client.get(.accounts) where Int64(remote.value.id) == account.remoteId {
            try await store.replaceAliases(
                try MirrorMapping.aliasRecords(remote, accountId: account.id), accountId: account.id)
        }
        let list = try await client.get(Endpoint.mailboxes(accountId: Int(account.remoteId)))
        try await store.upsert(
            mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: account.id) },
            accountId: account.id)
        let inbox = try #require(
            try await store.mailboxes(accountId: account.id).first { $0.specialRole?.lowercased() == "inbox" })
        _ = try await CalendarListSync(store: store, client: dav, loginId: loginId).runPass()

        let configuration = MutationQueueConfiguration(dav: ContactWriteHandler(store: store, client: dav))
        let drainer = OperationDrainer(
            store: store, client: client, accountId: account.id, configuration: configuration)
        // No drainer on the queue: rows wait, as offline, until the test drains.
        let queue = MutationQueue(store: store, configuration: configuration)
        let model = MessageCalendarModel(
            services: MessageViewServices(
                store: store, client: client, server: server,
                serverResults: ServerResultFetcher(store: store, client: client, identity: identity),
                queue: queue, exporter: MessageExporter(store: store, client: client)))
        return Live(
            store: store, client: client, dav: dav, identity: identity, loginId: loginId, account: account,
            inbox: inbox, drainer: drainer, queue: queue, model: model,
            calendars: try await store.calendars(loginId: loginId))
    }

    /// The seeded message whose subject carries `suffix`, envelope and body in the mirror.
    private static func mirror(_ live: Live, suffix: String) async throws -> (id: Int64, remoteId: Int64) {
        let token = try #require(environment["NCMAIL_LIVE_WS34_TOKEN"])
        _ = try? await live.client.post(.sync(mailboxId: Int(live.inbox.remoteId)))
        // The newest page rather than a `subject:` search: measured 2026-10-04, the search
        // answered only one of the two seeded messages.
        let found = try await live.client.get(.messages(mailboxId: Int(live.inbox.remoteId), limit: 50))
        guard let envelope = found.first(where: { $0.value.subject == "\(token) \(suffix)" }) else {
            throw LiveError.notFound(suffix)
        }
        let ids = try await live.store.upsert(envelopes: [
            try MirrorMapping.envelopeWrite(envelope, accountId: live.account.id, mailboxId: live.inbox.id, syncedAt: 1)
        ])
        let id = try #require(ids.first)
        let body = try await live.client.get(.messageBody(id: envelope.value.id))
        try await live.store.upsert(body: try MirrorMapping.bodyWrite(body, html: nil, fetchedAt: 1), for: id)
        return (id, Int64(envelope.value.id))
    }

    private static func run(_ live: Live, message: (id: Int64, remoteId: Int64)) -> Task<Void, Never> {
        let context = MessageCalendarModel.Context(
            messageId: message.id, remoteId: message.remoteId, accountId: live.account.id, loginId: live.loginId)
        return Task { await live.model.run(context) }
    }

    /// Calendar objects in `calendarURL` whose UID is `uid`, with their data.
    private static func objects(
        _ dav: DAVClient, in calendarURL: URL, uid: String, component: String = "VEVENT"
    )
        async throws -> [DAVResource]
    {
        let query = """
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/>\
            <c:calendar-data/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="\(component)">\
            <c:prop-filter name="UID"><c:text-match collation="i;octet">\(uid)</c:text-match></c:prop-filter>\
            </c:comp-filter></c:comp-filter></c:filter></c:calendar-query>
            """
        return try await dav.report(calendarURL, body: Data(query.utf8), depth: .one).responses
            .filter { $0.calendarData != nil }
    }

    static func report(_ line: String) {
        FileHandle.standardError.write(Data("  [measured] live WS-34: \(line)\n".utf8))
    }

    // MARK: - Acceptance

    /// Accept a same-server invitation from the card: the queued answer reaches the
    /// attendee's copy (the server's `sabredav-….ics`, via the 409 re-target), and the
    /// server's scheduling flips the organiser's copy and drops a REPLY in their inbox.
    @Test(.enabled(if: hasLiveServer), .timeLimit(.minutes(3)))
    func acceptingAnInvitationRepliesToTheOrganiser() async throws {
        let live = try await Self.live()
        let uid = try #require(Self.environment["NCMAIL_LIVE_WS34_UID"])
        let organizerName = try #require(Self.environment["NCMAIL_LIVE_WS34_ORGANIZER"])
        let organizerPassword = try #require(Self.environment["NCMAIL_LIVE_WS34_ORGANIZER_PASSWORD"])
        let message = try await Self.mirror(live, suffix: "invitation")
        let task = Self.run(live, message: message)
        defer { task.cancel() }
        try await CalendarTestSupport.until { !live.model.invitations.isEmpty && !live.model.calendars.isEmpty }

        let invitation = try #require(live.model.invitations.first { $0.uid == uid })
        #expect(live.model.state(of: invitation) == .invited)
        let target = try #require(CalendarObjects.preferred(live.model.eventCalendars))
        let targetURL = try #require(URL(string: target.url))
        let before = try await Self.objects(live.dav, in: targetURL, uid: uid)
        #expect(before.count == 1, "scheduling delivered the attendee's copy")

        await live.model.answer(invitation, .accepted, comment: "WS-34 live: see you there", in: target)
        #expect(live.model.failure == nil)
        #expect(live.model.state(of: invitation) == .answered(.accepted))
        #expect(try await live.queue.pendingDAVWrites(loginId: live.loginId).count == 1)

        let started = ContinuousClock.now
        await live.drainer.drain()
        let drained = ContinuousClock.now - started
        #expect(try await live.queue.pendingDAVWrites(loginId: live.loginId).isEmpty)

        // The attendee still has one copy, now accepted.
        let after = try await Self.objects(live.dav, in: targetURL, uid: uid)
        #expect(after.count == 1)
        #expect(after.first?.href == before.first?.href)
        let mine = try ICalendar.parse(try #require(after.first?.calendarData))
        let me = try #require(invitation.me(in: live.model.addresses)?.email)
        let myLine = mine.events.first?.attendee(matching: me)
        #expect(myLine?.partstat == .accepted)
        #expect(myLine?.responseComment == "WS-34 live: see you there")

        // The organiser's side, read as the organiser.
        let base = try #require(URL(string: live.identity.serverURL))
        let organizer = DAVClient(
            server: base, credentials: BasicCredentials(loginName: organizerName, appPassword: organizerPassword))
        let personal = organizer.resolve(href: "/remote.php/dav/calendars/\(organizerName)/personal/")
        let theirs = try await Self.objects(organizer, in: personal, uid: uid)
        let theirData = try #require(theirs.first?.calendarData)
        let theirEvent = try #require(try ICalendar.parse(theirData).events.first)
        let answered = try #require(theirEvent.attendee(matching: me))
        #expect(answered.partstat == .accepted)
        // Measured: Sabre's REPLY carries PARTSTAT and CN only, so the comment stays on the
        // attendee's copy — the web client's answer reaches the organiser the same way.

        let inboxURL = organizer.resolve(href: "/remote.php/dav/calendars/\(organizerName)/inbox/")
        let listed = try await organizer.propfind(inboxURL, depth: .one, properties: [.getetag])
            .map(\.href).filter { $0.hasSuffix(".ics") }
        let replies = try await organizer.calendarMultiget(inboxURL, hrefs: listed)
            .compactMap(\.calendarData)
            .filter { $0.contains("METHOD:REPLY") && $0.contains(uid) && $0.contains("PARTSTAT=ACCEPTED") }
        // Measured: one REPLY for the refused PUT (Sabre schedules before the UID check) and
        // one for the re-PUT — both ACCEPTED (ADR-0093).
        #expect(!replies.isEmpty)
        Self.report(
            "answer queued offline, drained in \(drained); attendee copy \(after.first?.href ?? "-"); organiser copy ACCEPTED; \(replies.count) REPLY in the organiser's inbox"
        )
    }

    /// Create task: a VTODO in a task list, where web Tasks/Calendar read it.
    @Test(.enabled(if: hasLiveServer), .timeLimit(.minutes(2)))
    func createdTaskLandsInTheTaskList() async throws {
        let live = try await Self.live()
        let message = try await Self.mirror(live, suffix: "invitation")
        let task = Self.run(live, message: message)
        defer { task.cancel() }
        try await CalendarTestSupport.until { !live.model.calendars.isEmpty }
        let list = try #require(live.model.taskCalendars.first)
        let uid = "ws34-live-task-\(UUID().uuidString)"
        var draft = TaskDraft.initial(subject: "WS-34 live task", preview: "From the message view")
        draft.due = Date().addingTimeInterval(86_400)
        try await CalendarActions(loginId: live.loginId, queue: live.queue).put(draft.calendar(uid: uid), into: list)
        await live.drainer.drain()

        let listURL = try #require(URL(string: list.url))
        let found = try await Self.objects(live.dav, in: listURL, uid: uid, component: "VTODO")
        #expect(found.count == 1)
        #expect(found.first?.calendarData?.contains("SUMMARY:WS-34 live task") == true)
        Self.report("VTODO \(found.first?.href ?? "-") in \(list.displayName ?? list.url)")
        if Self.environment["NCMAIL_LIVE_KEEP"] != "1", let href = found.first?.href {
            try await live.dav.delete(live.dav.resolve(href: href))
        }
    }

    /// The server's extractor reads the seeded confirmation; importing it twice leaves one
    /// event (same UID → the second write updates the first, ADR-0093).
    @Test(.enabled(if: hasLiveServer), .timeLimit(.minutes(2)))
    func itineraryImportsOnceByUID() async throws {
        let live = try await Self.live()
        let message = try await Self.mirror(live, suffix: "flight")
        let task = Self.run(live, message: message)
        defer { task.cancel() }
        try await CalendarTestSupport.until { !live.model.itinerary.isEmpty && !live.model.calendars.isEmpty }

        let entry = try #require(live.model.itinerary.first)
        #expect(entry.kind == .flight)
        #expect(entry.canImport)
        let target = try #require(CalendarObjects.preferred(live.model.eventCalendars))
        await live.model.importEntry(entry, into: target)
        await live.model.importEntry(entry, into: target)
        #expect(try await live.queue.pendingDAVWrites(loginId: live.loginId).count == 2)
        await live.drainer.drain()

        let found = try await Self.objects(live.dav, in: try #require(URL(string: target.url)), uid: entry.uid)
        #expect(found.count == 1)
        #expect(try await live.queue.pendingDAVWrites(loginId: live.loginId).isEmpty)
        Self.report("itinerary \(live.model.itinerary.count) card(s); 2 imports → \(found.count) event \(entry.uid)")
        if Self.environment["NCMAIL_LIVE_KEEP"] != "1", let href = found.first?.href {
            try await live.dav.delete(live.dav.resolve(href: href))
        }
    }
}
