// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailNet

/// Principal discovery against a real server — the manual check the WS-17
/// brief requires, kept runnable:
///
/// ```
/// NCMAIL_LIVE_DAV=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter discoversTheLivePrincipal
/// ```
///
/// Gated on the environment like the other live suites (`NCMAIL_LIVE_SYNC`,
/// `NCMAIL_LIVE_MIRROR`), so CI and plain `swift test` never touch a network.
@Suite("DAV against a live server")
struct DAVLiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_DAV"]

    enum LiveError: Error { case missingEnvironment }

    private static func makeClient() throws -> DAVClient {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_DAV"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }
        return DAVClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password)
        )
    }

    @Test(.enabled(if: serverEnvironment != nil))
    func discoversTheLivePrincipal() async throws {
        let client = try Self.makeClient()

        let principal = try await client.currentUserPrincipal()
        #expect(principal.path().contains("/principals/users/"))

        let homes = try await client.homeSets(of: principal)
        let addressbookHome = try #require(homes.addressbookHome)
        let calendarHome = try #require(homes.calendarHome)
        #expect(addressbookHome.path().contains("/addressbooks/"))
        #expect(calendarHome.path().contains("/calendars/"))

        // And the home actually lists at least one addressbook, which is the
        // milestone M8 gate: "a CardDAV sync-collection against the live
        // server lists the user's address books".
        let resources = try await client.propfind(
            addressbookHome,
            depth: .one,
            properties: [.resourcetype, .displayname, .syncToken]
        )
        let books = resources.filter(\.isAddressbook)
        #expect(!books.isEmpty)

        // sync-collection answers a token for the first book.
        let bookURL = try #require(books.first.map { client.resolve(href: $0.href) })
        let changes = try await client.syncCollection(bookURL, token: nil)
        #expect(!changes.newToken.isEmpty)
    }
}
