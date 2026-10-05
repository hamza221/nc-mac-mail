// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailNet
internal import NCMailStore

/// DAV property names the contacts and calendar mirrors ask for beyond `DAVClient`'s own.
enum MirrorDAVNames {
    static let ocEnabled = DAVQualifiedName(DAVQualifiedName.owncloud, "enabled")
    static let ocReadOnly = DAVQualifiedName(DAVQualifiedName.owncloud, "read-only")
    static let ocOwnerPrincipal = DAVQualifiedName(DAVQualifiedName.owncloud, "owner-principal")
    static let writeContent = DAVQualifiedName(DAVQualifiedName.dav, "write-content")
    static let write = DAVQualifiedName(DAVQualifiedName.dav, "write")
    static let all = DAVQualifiedName(DAVQualifiedName.dav, "all")
    static let calendarColor = DAVQualifiedName("http://apple.com/ns/ical/", "calendar-color")
    static let calendarOrder = DAVQualifiedName("http://apple.com/ns/ical/", "calendar-order")
    static let scheduleDefaultCalendarURL = DAVQualifiedName(DAVQualifiedName.caldav, "schedule-default-calendar-URL")

    /// `write-content` is what PUT needs; `write` and `all` aggregate it (RFC 3744 §3.12).
    static func canWriteContent(_ resource: DAVResource) -> Bool? {
        let privileges = resource.privileges
        guard !privileges.isEmpty else { return nil }
        return privileges.contains(writeContent) || privileges.contains(write) || privileges.contains(all)
    }

    /// `oc:owner-principal` as Nextcloud spells it: `principals/users/alice`, no leading
    /// slash. Nil when the server did not say or when it names the login's own principal.
    static func sharedBy(_ resource: DAVResource, ownPrincipalPath: String?) -> String? {
        guard let owner = resource.property(ocOwnerPrincipal)?.text?.trimmingCharacters(in: .whitespaces),
            !owner.isEmpty
        else { return nil }
        let normalized = owner.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let own = ownPrincipalPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            own.hasSuffix(normalized)
        {
            return nil
        }
        return normalized
    }
}

/// One address book as the server lists it (fixture `dav-addressbooks-ws24.xml`).
public struct AddressBookListing: Sendable, Equatable {
    /// Absolute collection URL, trailing slash — `addressBook.url`.
    public var url: String
    public var displayName: String?
    /// `oc:enabled` = `0` disables; absent means enabled. The toggle web Contacts writes.
    public var isEnabled: Bool
    /// `oc:read-only` = `1`, or no `write-content` in the privilege set.
    public var isReadOnly: Bool
    /// The owner's principal when the book is someone else's: shared with us, or the
    /// system "Accounts" book (`principals/system/system`).
    public var sharedBy: String?
    /// The server's current token — compared with the stored one to skip unchanged books.
    public var syncToken: String?

    /// What `ContactsSync` asks the address book home for.
    static let properties: [DAVQualifiedName] = [
        .resourcetype, .displayname, .syncToken, .currentUserPrivilegeSet,
        MirrorDAVNames.ocEnabled, MirrorDAVNames.ocReadOnly, MirrorDAVNames.ocOwnerPrincipal,
    ]

    /// The address books of a Depth-1 listing, in server order; the home itself and any
    /// non-addressbook collection are dropped.
    static func parse(_ resources: [DAVResource], client: DAVClient, ownPrincipalPath: String?) -> [AddressBookListing]
    {
        resources.filter(\.isAddressbook).map { resource in
            let readOnlyFlag = resource.property(MirrorDAVNames.ocReadOnly)?.text?.trimmingCharacters(in: .whitespaces)
            let readOnly =
                readOnlyFlag == "1" || readOnlyFlag?.lowercased() == "true"
                || MirrorDAVNames.canWriteContent(resource) == false
            let enabledFlag = resource.property(MirrorDAVNames.ocEnabled)?.text?.trimmingCharacters(in: .whitespaces)
            return AddressBookListing(
                url: collectionURLString(client.resolve(href: resource.href)),
                displayName: resource.displayName,
                isEnabled: !(enabledFlag == "0" || enabledFlag?.lowercased() == "false"),
                isReadOnly: readOnly,
                sharedBy: MirrorDAVNames.sharedBy(resource, ownPrincipalPath: ownPrincipalPath),
                syncToken: resource.syncToken
            )
        }
    }

    func record(loginId: Int64, position: Int) -> AddressBookRecord {
        AddressBookRecord(
            loginId: loginId,
            url: url,
            displayName: displayName,
            isReadOnly: isReadOnly,
            isEnabled: isEnabled,
            sharedBy: sharedBy,
            position: position
        )
    }
}

/// One spelling for a collection URL, so the listing, a queued create and the store agree:
/// absolute, with a trailing slash.
func collectionURLString(_ url: URL) -> String {
    let string = url.absoluteString
    return string.hasSuffix("/") ? string : string + "/"
}
