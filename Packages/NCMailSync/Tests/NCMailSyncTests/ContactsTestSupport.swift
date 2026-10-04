// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// A store with one login, a fake transport and a DAV client on `cloud.example.com` — the
/// host every recorded DAV fixture is scrubbed to.
struct ContactsHarness {
    let store: MailStore
    let transport: FakeTransport
    let client: DAVClient
    let loginId: Int64

    init() async throws {
        store = try MailStore.inMemory()
        transport = FakeTransport()
        let server = try #require(URL(string: "https://cloud.example.com"))
        client = DAVClient(
            server: server,
            credentials: BasicCredentials(loginName: "user", appPassword: "secret"),
            transport: transport
        )
        let login = try await store.ensureLogin(ServerIdentity(serverURL: server, loginName: "user"))
        loginId = try #require(login.id)
    }

    static let home = "/remote.php/dav/addressbooks/users/user/"
    static let contactsBook = "https://cloud.example.com/remote.php/dav/addressbooks/users/user/contacts/"

    /// Principal discovery and the recorded address book listing.
    func stubDiscoveryAndListing() async throws {
        await transport.stub(
            .propfind && .path("/remote.php/dav"), with: try .fixture("dav-current-user-principal.xml", status: 207))
        await transport.stub(
            .propfind && .pathContains("/principals/users/") && .bodyContains("addressbook-home-set"),
            with: try .fixture("dav-principal-home-sets.xml", status: 207))
        await transport.stub(
            .propfind && .pathSuffix("/addressbooks/users/user"),
            with: try .fixture("dav-addressbooks-ws24.xml", status: 207))
    }

    /// Every book other than the one a test cares about answers "nothing in here" — the
    /// token-less "Recently contacted" through its ETag listing.
    func stubOtherBooksEmpty() async throws {
        await transport.stub(
            .report && .bodyContains("sync-collection"), with: try .fixture("dav-sync-empty.xml", status: 207))
        await transport.stub(
            .propfind && .pathContains("contactsinteraction"), with: try .fixture("dav-sync-empty.xml", status: 207))
    }

    func sync(pending: [DAVWrite] = []) -> ContactsSync {
        ContactsSync(store: store, client: client, loginId: loginId, pendingWrites: { pending })
    }

    func book(_ url: String = Self.contactsBook) async throws -> AddressBookRecord {
        try #require(try await store.addressBooks(loginId: loginId).first { $0.url == url })
    }

    /// The `address-data` of a recorded multiget, as text — fetched through the real client
    /// so the test reads exactly what the sync reads.
    static func cardText(fixture: String) async throws -> (text: String, etag: String?) {
        let transport = FakeTransport()
        let client = DAVClient(
            server: try #require(URL(string: "https://cloud.example.com")),
            credentials: BasicCredentials(loginName: "user", appPassword: "secret"),
            transport: transport
        )
        await transport.stub(.report, with: try .fixture(fixture, status: 207))
        let resources = try await client.addressbookMultiget(
            try #require(URL(string: Self.contactsBook)), hrefs: ["x"])
        let resource = try #require(resources.first { $0.addressData != nil })
        return (try #require(resource.addressData), resource.etag)
    }
}
