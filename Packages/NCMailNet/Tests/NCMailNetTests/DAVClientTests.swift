// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailTestSupport
import Testing

@testable import NCMailNet

@Suite("DAVClient against recorded Nextcloud answers")
struct DAVClientTests {
    private let server: URL
    private let transport: FakeTransport
    private let client: DAVClient

    init() throws {
        server = try #require(URL(string: "https://cloud.example.com"))
        transport = FakeTransport()
        client = DAVClient(
            server: server,
            credentials: BasicCredentials(loginName: "user", appPassword: "secret"),
            transport: transport
        )
    }

    private func url(_ path: String) throws -> URL {
        try #require(URL(string: path, relativeTo: server))
    }

    // MARK: - Principal discovery

    @Test func discoversPrincipalAndHomeSets() async throws {
        await transport.stub(
            .propfind && .path("/remote.php/dav"),
            with: try .fixture("dav-current-user-principal.xml", status: 207)
        )
        await transport.stub(
            .propfind && .pathContains("/principals/users/"),
            with: try .fixture("dav-principal-home-sets.xml", status: 207)
        )

        let homes = try await client.discoverHomeSets()
        #expect(homes.addressbookHome?.path() == "/remote.php/dav/addressbooks/users/user/")
        #expect(homes.calendarHome?.path() == "/remote.php/dav/calendars/user/")

        // Both PROPFINDs went out with Depth: 0 and asked for the right props.
        let requests = await transport.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Depth") == "0")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        }
        let first = try #require(requests.first?.httpBody)
        #expect(String(decoding: first, as: UTF8.self).contains("current-user-principal"))
        let second = try #require(requests.last?.httpBody)
        #expect(String(decoding: second, as: UTF8.self).contains("addressbook-home-set"))
    }

    @Test func listsAddressbooksAtDepthOne() async throws {
        await transport.stub(.propfind, with: try .fixture("dav-addressbooks-depth1.xml", status: 207))

        let resources = try await client.propfind(
            try url("/remote.php/dav/addressbooks/users/user/"),
            depth: .one,
            properties: [.resourcetype, .displayname, .getctag, .syncToken]
        )
        let books = resources.filter(\.isAddressbook)
        #expect(!books.isEmpty)
        let contacts = try #require(
            books.first { $0.href.hasSuffix("/contacts/") })
        #expect(contacts.isCollection)
        #expect(contacts.displayName == "Contacts")
        #expect(contacts.syncToken?.isEmpty == false)
        // The home itself is in the answer but is not an addressbook.
        #expect(resources.contains { $0.isCollection && !$0.isAddressbook })

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Depth") == "1")
    }

    @Test func listsCalendarsWithTheirComponentSets() async throws {
        await transport.stub(.propfind, with: try .fixture("dav-calendars-depth1.xml", status: 207))

        let resources = try await client.propfind(
            try url("/remote.php/dav/calendars/user/"),
            depth: .one,
            properties: [.resourcetype, .displayname, .supportedCalendarComponentSet]
        )
        let calendars = resources.filter(\.isCalendar)
        #expect(!calendars.isEmpty)
        // The recorded server has the default event calendar and the VTODO one
        // this workstream created.
        #expect(calendars.contains { $0.supportedCalendarComponents.contains("VEVENT") })
        #expect(calendars.contains { $0.supportedCalendarComponents.contains("VTODO") })
    }

    /// `current-user-privilege-set` nests each privilege one level down; the parser
    /// lifts the names so writability is a lookup. The birthday calendar is the case
    /// `oc:read-only` misses (WS-24, measured).
    @Test func privilegesComeBackFlatFromTheNestedSet() async throws {
        await transport.stub(.propfind, with: try .fixture("dav-calendars-ws24.xml", status: 207))

        let resources = try await client.propfind(
            try url("/remote.php/dav/calendars/user/"),
            depth: .one,
            properties: [.resourcetype, .currentUserPrivilegeSet]
        )
        let writeContent = DAVQualifiedName(DAVQualifiedName.dav, "write-content")
        let personal = try #require(resources.first { $0.href.hasSuffix("/personal/") })
        let birthdays = try #require(resources.first { $0.href.hasSuffix("/contact_birthdays/") })
        #expect(personal.privileges.contains(writeContent))
        #expect(personal.privileges.contains(DAVQualifiedName(DAVQualifiedName.dav, "read")))
        #expect(!personal.privileges.contains(DAVQualifiedName(DAVQualifiedName.dav, "privilege")))
        #expect(!birthdays.privileges.contains(writeContent))
        #expect(birthdays.privileges.contains(DAVQualifiedName(DAVQualifiedName.dav, "read")))
    }

    // MARK: - sync-collection

    @Test func initialSyncListsEveryMemberAndAToken() async throws {
        await transport.stub(.report, with: try .fixture("dav-sync-initial.xml", status: 207))

        let changes = try await client.syncCollection(
            try url("/remote.php/dav/addressbooks/users/user/contacts/"), token: nil)

        #expect(!changes.changed.isEmpty)
        #expect(changes.removed.isEmpty)
        #expect(!changes.truncated)
        #expect(changes.newToken.hasPrefix("http://sabre.io/ns/sync/"))
        for resource in changes.changed {
            #expect(resource.href.hasSuffix(".vcf"))
            #expect(resource.etag?.isEmpty == false)
        }

        // An initial sync sends the empty token element.
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("<d:sync-token/>"))
        #expect(request.value(forHTTPHeaderField: "Depth") == "0")
    }

    @Test func incrementalSyncSeparatesChangedFromRemoved() async throws {
        await transport.stub(.report, with: try .fixture("dav-sync-incremental.xml", status: 207))

        let changes = try await client.syncCollection(
            try url("/remote.php/dav/addressbooks/users/user/contacts/"),
            token: "http://sabre.io/ns/sync/9")

        #expect(changes.changed.count == 1)
        #expect(changes.removed.count == 1)
        #expect(changes.removed.first?.path().hasSuffix(".vcf") == true)
        #expect(!changes.truncated)

        // The previous token went out in the body.
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("<d:sync-token>http://sabre.io/ns/sync/9</d:sync-token>"))
    }

    @Test func truncatedSyncSurfacesTheFlagAndKeepsTheToken() async throws {
        // Nextcloud's truncation is a 207 whose extra response carries
        // `HTTP/1.1 507 Insufficient Storage` for the collection itself —
        // recorded, not guessed (fixture + ADR-0076).
        await transport.stub(.report, with: try .fixture("dav-sync-truncated.xml", status: 207))

        let changes = try await client.syncCollection(
            try url("/remote.php/dav/addressbooks/users/user/contacts/"), token: nil)

        #expect(changes.truncated)
        #expect(!changes.newToken.isEmpty)
        #expect(!changes.changed.isEmpty)
        // The 507 marker is neither a change nor a removal.
        #expect(changes.changed.allSatisfy { $0.href.hasSuffix(".vcf") })
        #expect(changes.removed.isEmpty)
    }

    @Test func syncWithoutATokenInTheAnswerThrows() async throws {
        // A multistatus without a sync-token: the recorded PROPPATCH answer.
        await transport.stub(.report, with: try .fixture("dav-proppatch.xml", status: 207))

        await #expect(throws: DAVError.self) {
            _ = try await client.syncCollection(
                try url("/remote.php/dav/addressbooks/users/user/contacts/"), token: nil)
        }
    }

    // MARK: - Multiget

    @Test func addressbookMultigetCarriesWholeVCards() async throws {
        await transport.stub(.report, with: try .fixture("dav-addressbook-multiget.xml", status: 207))

        let resources = try await client.addressbookMultiget(
            try url("/remote.php/dav/addressbooks/users/user/contacts/"),
            hrefs: [
                "/remote.php/dav/addressbooks/users/user/contacts/ws17-alice.vcf",
                "/remote.php/dav/addressbooks/users/user/contacts/ws17-bob.vcf",
            ]
        )
        #expect(resources.count == 2)
        for resource in resources {
            #expect(resource.etag?.isEmpty == false)
            let vcard = try #require(resource.addressData)
            #expect(vcard.hasPrefix("BEGIN:VCARD"))

            // The cards the server actually serves round-trip too — the
            // acceptance bar applied to the bytes WS-24 will store.
            let cards = try VCardParser.parse(Data(vcard.utf8))
            #expect(cards.count == 1)
            let emitted = String(decoding: VCardSerializer.serialize(cards), as: UTF8.self)
            #expect(Self.unfolded(emitted) == Self.unfolded(vcard))
        }

        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("addressbook-multiget"))
        #expect(body.contains("ws17-alice.vcf"))
    }

    /// Logical lines, so two vCards compare "modulo line folding".
    private static func unfolded(_ text: String) -> [String] {
        text.replacing("\r\n ", with: "").replacing("\r\n\t", with: "")
            .split(separator: "\r\n").map(String.init)
    }

    @Test func calendarMultigetCarriesCalendarData() async throws {
        await transport.stub(.report, with: try .fixture("dav-calendar-multiget.xml", status: 207))

        let resources = try await client.calendarMultiget(
            try url("/remote.php/dav/calendars/user/personal/"),
            hrefs: ["/remote.php/dav/calendars/user/personal/ws17-standup.ics"]
        )
        let found = try #require(resources.first { $0.status == nil })
        let calendar = try #require(found.calendarData)
        #expect(calendar.hasPrefix("BEGIN:VCALENDAR"))
    }

    // MARK: - Writes

    @Test func putReturnsTheETagAndSendsIfMatch() async throws {
        await transport.stub(
            .method("PUT"),
            with: NCMailTestSupport.StubResponse(status: 204, headers: ["ETag": "\"abc123\""])
        )

        let etag = try await client.put(
            try url("/remote.php/dav/addressbooks/users/user/contacts/x.vcf"),
            data: Data("BEGIN:VCARD\r\nEND:VCARD\r\n".utf8),
            contentType: "text/vcard; charset=utf-8",
            ifMatch: "\"old-etag\""
        )
        #expect(etag == "\"abc123\"")

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "If-Match") == "\"old-etag\"")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/vcard; charset=utf-8")
    }

    @Test func putWithoutAnETagInTheAnswerReturnsNil() async throws {
        // RFC 6352 §6.3.2.3: a server that alters the stored object must not
        // return a strong ETag. The client must accept that shape.
        await transport.stub(.method("PUT"), with: .status(201))
        let etag = try await client.put(
            try url("/remote.php/dav/addressbooks/users/user/contacts/x.vcf"),
            data: Data(),
            contentType: "text/vcard; charset=utf-8"
        )
        #expect(etag == nil)
    }

    @Test func staleIfMatchSurfacesAsPreconditionFailed() async throws {
        await transport.stub(.method("PUT"), with: .status(412))
        await #expect(throws: DAVError.self) {
            try await client.put(
                try url("/remote.php/dav/addressbooks/users/user/contacts/x.vcf"),
                data: Data(),
                contentType: "text/vcard; charset=utf-8",
                ifMatch: "\"stale\""
            )
        }
    }

    @Test("a PUT whose UID the calendar already holds names the existing object (recorded 409)")
    func uidConflictSurfacesTheExistingHref() async throws {
        await transport.stub(.method("PUT"), with: try .fixture("dav-error-uid-conflict-ws34.xml", status: 409))
        do {
            _ = try await client.put(
                try url("/remote.php/dav/calendars/user/personal/ws34-second.ics"),
                data: Data(),
                contentType: "text/calendar; charset=utf-8"
            )
            Issue.record("expected a uidConflict")
        } catch DAVError.uidConflict(let href) {
            #expect(href == "/remote.php/dav/calendars/user/personal/ws34-first.ics")
        }
    }

    @Test("a 409 without the CalDAV precondition stays a collection conflict")
    func plainConflictStaysACollectionConflict() async throws {
        await transport.stub(.method("PUT"), with: .status(409))
        do {
            _ = try await client.put(
                try url("/remote.php/dav/calendars/user/personal/x.ics"),
                data: Data(),
                contentType: "text/calendar; charset=utf-8"
            )
            Issue.record("expected a collectionConflict")
        } catch DAVError.collectionConflict(let status, _) {
            #expect(status == 409)
        }
    }

    @Test func deleteSendsIfMatch() async throws {
        await transport.stub(.method("DELETE"), with: .status(204))
        try await client.delete(
            try url("/remote.php/dav/addressbooks/users/user/contacts/x.vcf"),
            ifMatch: "\"abc\"")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "If-Match") == "\"abc\"")
    }

    @Test func extendedMkcolSendsResourceTypeAndProperties() async throws {
        // The live server answers 201 with an empty body (recorded:
        // dav-mkcol-response.xml is zero bytes).
        await transport.stub(.mkcol, with: .status(201))
        try await client.mkcolExtended(
            try url("/remote.php/dav/addressbooks/users/user/newbook/"),
            resourceTypes: [.addressbook],
            properties: [DAVProposedProperty(.displayname, "New Book")]
        )
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>"))
        #expect(body.contains("<d:displayname>New Book</d:displayname>"))
    }

    @Test func proppatchAcceptsTheRecordedSuccess() async throws {
        await transport.stub(.proppatch, with: try .fixture("dav-proppatch.xml", status: 207))
        try await client.proppatch(
            try url("/remote.php/dav/addressbooks/users/user/contacts/"),
            set: [DAVProposedProperty(.displayname, "Renamed")]
        )
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("<d:set><d:prop><d:displayname>Renamed</d:displayname></d:prop></d:set>"))
    }

    @Test func proppatchThrowsWhenAPropertyIsRefused() async throws {
        // The failure shape is the recorded success with the per-property
        // status flipped — the envelope is the server's, the status is the one
        // RFC 4918 §9.2 defines for a protected property.
        let recorded = try FixtureBytes.data("dav-proppatch.xml")
        let refused = String(decoding: recorded, as: UTF8.self)
            .replacingOccurrences(of: "HTTP/1.1 200 OK", with: "HTTP/1.1 403 Forbidden")
        await transport.stub(
            .proppatch, with: NCMailTestSupport.StubResponse(status: 207, body: Data(refused.utf8)))

        await #expect(throws: DAVError.self) {
            try await client.proppatch(
                try url("/remote.php/dav/addressbooks/users/user/contacts/"),
                set: [DAVProposedProperty(.displayname, "Renamed")]
            )
        }
    }

    @Test func shareBuildsTheNextcloudBody() async throws {
        // The live server answers 200 with an empty body (recorded:
        // dav-share-response.xml is zero bytes).
        await transport.stub(.method("POST"), with: .status(200))
        try await client.share(
            try url("/remote.php/dav/addressbooks/users/user/contacts/"),
            with: "principal:principals/users/colleague",
            readOnly: true
        )
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("<d:href>principal:principals/users/colleague</d:href>"))
        #expect(body.contains("<o:read/>"))
        #expect(!body.contains("read-write"))
    }

    // MARK: - Favourites and social avatars (WS-35)

    /// The recorded Depth-1 listing: the favourited card answers `"1"`, the other comes back
    /// in a 404 propstat — false, not "unknown" — and the collection itself is neither.
    @Test func favoriteListingReadsTheDeadProperty() async throws {
        await transport.stub(.propfind, with: try .fixture("dav-ws35-favorites.xml", status: 207))
        let resources = try await client.propfind(
            try url("/remote.php/dav/addressbooks/users/user/ws35-temp-fav/"), depth: .one,
            properties: [.getetag, .favorite])
        let favourite = try #require(resources.first { $0.href.hasSuffix("/ws35-fav.vcf") })
        let plain = try #require(resources.first { $0.href.hasSuffix("/ws35-social.vcf") })
        #expect(favourite.isFavorite == true)
        #expect(plain.isFavorite == false)

        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains(#"xmlns:nc="http://nextcloud.com/ns""#))
        #expect(body.contains("<nc:favorite/>"))
    }

    @Test func multigetAsksForAndReadsTheFavourite() async throws {
        await transport.stub(.report, with: try .fixture("dav-ws35-multiget-favorite.xml", status: 207))
        let resources = try await client.addressbookMultiget(
            try url("/remote.php/dav/addressbooks/users/user/ws35-temp-fav/"),
            hrefs: ["/remote.php/dav/addressbooks/users/user/ws35-temp-fav/ws35-fav.vcf"])
        #expect(resources.first { $0.href.hasSuffix("/ws35-fav.vcf") }?.isFavorite == true)
        #expect(resources.first { $0.href.hasSuffix("/ws35-social.vcf") }?.isFavorite == false)
        #expect(resources.allSatisfy { $0.addressData != nil })
        let body = String(decoding: try #require(await transport.requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("<card:address-data/><nc:favorite/>"))
    }

    @Test func setFavoriteSetsAndRemovesTheProperty() async throws {
        await transport.stubSequence(
            .proppatch,
            [
                try .fixture("dav-ws35-favorite-proppatch.xml", status: 207),
                try .fixture("dav-ws35-favorite-unproppatch.xml", status: 207),
            ])
        let card = try url("/remote.php/dav/addressbooks/users/user/ws35-temp-fav/ws35-fav.vcf")
        try await client.setFavorite(card, true)
        try await client.setFavorite(card, false)
        let bodies = await transport.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        #expect(bodies.count == 2)
        #expect(bodies.first?.contains("<d:set><d:prop><nc:favorite>1</nc:favorite></d:prop></d:set>") == true)
        #expect(bodies.last?.contains("<d:remove><d:prop><nc:favorite/></d:prop></d:remove>") == true)
        #expect(bodies.last?.contains("<d:set>") == false)
    }

    @Test func socialAvatarPutsTheContactsAppRoute() async throws {
        await transport.stub(.method("PUT"), with: try .fixture("contacts-social-avatar.json", status: 200))
        try await client.fetchSocialAvatar(network: "gravatar", addressBookURI: "contacts", contactUID: "abc-123")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/index.php/apps/contacts/api/v1/social/avatar/gravatar/contacts/abc-123")
        #expect(request.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    // MARK: - Errors

    @Test func sabreErrorBodiesBecomeDiagnostics() async throws {
        await transport.stub(
            .method("PUT"), with: try .fixture("dav-error-invalid-component.xml", status: 403))

        do {
            try await client.put(
                try url("/remote.php/dav/calendars/user/personal/task.ics"),
                data: Data(),
                contentType: "text/calendar; charset=utf-8"
            )
            Issue.record("a 403 must throw")
        } catch let DAVError.forbidden(exception, message) {
            #expect(exception == #"Sabre\CalDAV\Exception\InvalidComponentType"#)
            #expect(message == "iCalendar objects must at least have a component of type VEVENT")
        }
    }

    @Test func transportFailuresKeepOneErrorVocabulary() async throws {
        await transport.fail(.any, times: 1, then: .status(204))
        do {
            try await client.delete(try url("/remote.php/dav/x"))
            Issue.record("the failing transport must throw")
        } catch is DAVError {
            // DAVError.transport, not MailError — one vocabulary for callers.
        }
        // No retry happened: DAV mutations are the sync engine's to reissue.
        #expect(await transport.sendCount == 1)
    }
}
