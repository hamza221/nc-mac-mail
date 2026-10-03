// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// An XML name with its namespace. DAV property names collide without one:
/// `displayname` is `DAV:`, `getctag` is calendarserver.org's.
public struct DAVQualifiedName: Sendable, Hashable, CustomStringConvertible {
    public var namespace: String
    public var name: String

    public init(_ namespace: String, _ name: String) {
        self.namespace = namespace
        self.name = name
    }

    public var description: String { "{\(namespace)}\(name)" }

    // The namespaces this client speaks.
    public static let dav = "DAV:"
    public static let carddav = "urn:ietf:params:xml:ns:carddav"
    public static let caldav = "urn:ietf:params:xml:ns:caldav"
    public static let calendarserver = "http://calendarserver.org/ns/"
    public static let owncloud = "http://owncloud.org/ns"
    public static let nextcloud = "http://nextcloud.org/ns"
    public static let sabre = "http://sabredav.org/ns"

    // DAV:
    public static let resourcetype = DAVQualifiedName(dav, "resourcetype")
    public static let displayname = DAVQualifiedName(dav, "displayname")
    public static let getetag = DAVQualifiedName(dav, "getetag")
    public static let syncToken = DAVQualifiedName(dav, "sync-token")
    public static let currentUserPrincipal = DAVQualifiedName(dav, "current-user-principal")
    public static let collection = DAVQualifiedName(dav, "collection")
    public static let getcontenttype = DAVQualifiedName(dav, "getcontenttype")

    // CardDAV / CalDAV / calendarserver
    public static let addressbook = DAVQualifiedName(carddav, "addressbook")
    public static let addressbookHomeSet = DAVQualifiedName(carddav, "addressbook-home-set")
    public static let addressData = DAVQualifiedName(carddav, "address-data")
    public static let calendar = DAVQualifiedName(caldav, "calendar")
    public static let calendarHomeSet = DAVQualifiedName(caldav, "calendar-home-set")
    public static let calendarData = DAVQualifiedName(caldav, "calendar-data")
    public static let supportedCalendarComponentSet = DAVQualifiedName(caldav, "supported-calendar-component-set")
    public static let getctag = DAVQualifiedName(calendarserver, "getctag")
}

/// One element found inside a DAV property: its name and attributes.
/// `resourcetype`'s children name the collection kinds; CalDAV's `comp`
/// carries its component in a `name` attribute.
public struct DAVElement: Sendable, Equatable {
    public var name: DAVQualifiedName
    public var attributes: [String: String]
}

/// A property value as the multistatus carried it.
public enum DAVPropertyValue: Sendable, Equatable {
    /// Text content: an etag, a display name, a whole vCard.
    case text(String)
    /// `DAV: href` children: a principal, a home set.
    case hrefs([String])
    /// Non-href child elements: resource types, supported components.
    case elements([DAVElement])
    /// Present but empty — a 404 propstat lists requested names this way.
    case empty

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var hrefs: [String] {
        if case .hrefs(let values) = self { return values }
        return []
    }

    public var elements: [DAVElement] {
        if case .elements(let values) = self { return values }
        return []
    }
}

/// One `propstat` group: the properties that share one status.
public struct DAVPropstat: Sendable, Equatable {
    public var status: Int
    public var properties: [DAVQualifiedName: DAVPropertyValue]
}

/// One `response` of a multistatus.
public struct DAVResource: Sendable, Equatable {
    /// As the server sent it: host-relative (`/remote.php/dav/…`).
    public var href: String
    /// The response-level status — only present on the "bare" shape, like a
    /// sync-collection's 404 for a removed resource or its 507 truncation mark.
    public var status: Int?
    public var propstats: [DAVPropstat]

    /// The properties that came back 200, merged.
    public var okProperties: [DAVQualifiedName: DAVPropertyValue] {
        var merged: [DAVQualifiedName: DAVPropertyValue] = [:]
        for propstat in propstats where propstat.status == 200 {
            merged.merge(propstat.properties) { first, _ in first }
        }
        return merged
    }

    public func property(_ name: DAVQualifiedName) -> DAVPropertyValue? {
        okProperties[name]
    }

    // MARK: - Common properties, typed

    /// The etag with its surrounding quotes kept: `If-Match` wants the exact
    /// server token, and stripping quotes loses weak-validator prefixes.
    public var etag: String? { property(.getetag)?.text }
    public var displayName: String? { property(.displayname)?.text }
    public var syncToken: String? { property(.syncToken)?.text }
    public var ctag: String? { property(.getctag)?.text }
    public var addressData: String? { property(.addressData)?.text }
    public var calendarData: String? { property(.calendarData)?.text }

    public var resourceTypes: [DAVQualifiedName] {
        property(.resourcetype)?.elements.map(\.name) ?? []
    }
    public var isCollection: Bool { resourceTypes.contains(.collection) }
    public var isAddressbook: Bool { resourceTypes.contains(.addressbook) }
    public var isCalendar: Bool { resourceTypes.contains(.calendar) }

    /// CalDAV's `supported-calendar-component-set`, as component names.
    public var supportedCalendarComponents: [String] {
        property(.supportedCalendarComponentSet)?.elements.compactMap { $0.attributes["name"] } ?? []
    }

    /// The single href of an href-valued property: `current-user-principal`,
    /// the home sets.
    public func firstHref(_ name: DAVQualifiedName) -> String? {
        property(name)?.hrefs.first
    }
}

/// A parsed `207 Multi-Status` body.
public struct DAVMultistatus: Sendable, Equatable {
    public var responses: [DAVResource]
    /// RFC 6578: the token that resumes where this answer stopped.
    public var syncToken: String?
}

/// The `Depth` header, which DAV requires on PROPFIND and REPORT.
public enum DAVDepth: String, Sendable {
    case zero = "0"
    case one = "1"
    case infinity = "infinity"
}

/// A property to write: PROPPATCH sets and extended MKCOL bodies.
public struct DAVProposedProperty: Sendable, Equatable {
    public var name: DAVQualifiedName
    public var value: String

    public init(_ name: DAVQualifiedName, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// What `syncCollection` answers, split the way the sync engine consumes it.
public struct DAVSyncChanges: Sendable, Equatable {
    /// Resources to fetch or refresh, each with its etag.
    public var changed: [DAVResource]
    /// Resources the server deleted, resolved to absolute URLs.
    public var removed: [URL]
    /// Send this next time.
    public var newToken: String
    /// RFC 6578 truncation: the server stopped early (Nextcloud marks it with
    /// a per-collection 507 inside the 207). The token is still valid — call
    /// again with it until this clears. ADR-0076.
    public var truncated: Bool
}

/// The two discovery results principal discovery is for.
public struct DAVHomeSets: Sendable, Equatable {
    public var addressbookHome: URL?
    public var calendarHome: URL?
}
