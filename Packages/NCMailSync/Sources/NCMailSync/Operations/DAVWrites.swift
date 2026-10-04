// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailNet
public import NCMailStore

/// A queued CardDAV/CalDAV write: what to send, and what it overwrote.
///
/// One shape for the seven DAV kinds. Which fields matter is the kind's business:
///
/// | Kind | Uses |
/// | --- | --- |
/// | `contactPut` | `href`, `body` (the full vCard), `etag` (nil creates), `editedProperties` |
/// | `contactDelete` | `href`, `etag` |
/// | `addressBookCreate` | `href` (the new collection), `displayName`, `color` |
/// | `addressBookUpdate` | `href`, `displayName`, `color` |
/// | `addressBookDelete` | `href` |
/// | `addressBookShare` | `href`, `sharee`, `shareReadOnly` |
/// | `calendarPut` | `href`, `body` (the iCalendar object), `etag` |
///
/// Every `href` is the server's host-relative path, as a multistatus spells it.
public struct DAVWritePayload: Codable, Sendable, Equatable {
    public var loginId: Int64
    public var addressBookId: Int64?
    public var calendarId: Int64?
    public var contactId: Int64?
    /// The address book or calendar collection the object lives in.
    public var collectionHref: String?
    public var href: String?
    public var body: String?
    /// `If-Match`. Nil on a put means create, sent with no precondition.
    public var etag: String?
    /// vCard property names the user changed, which is what a 412 reapplies onto the
    /// server's newer copy (ADR-0069).
    public var editedProperties: [String]
    public var displayName: String?
    public var color: String?
    /// `principal:principals/users/<id>` or a group principal.
    public var sharee: String?
    public var shareReadOnly: Bool?
    /// The address book's on/off toggle, stored server-side as `oc:enabled` ("1"/"0";
    /// absent means enabled — measured by WS-24 against web Contacts).
    public var enabled: Bool?
    public var before: DAVWriteSnapshot

    public init(
        loginId: Int64,
        addressBookId: Int64? = nil,
        calendarId: Int64? = nil,
        contactId: Int64? = nil,
        collectionHref: String? = nil,
        href: String? = nil,
        body: String? = nil,
        etag: String? = nil,
        editedProperties: [String] = [],
        displayName: String? = nil,
        color: String? = nil,
        sharee: String? = nil,
        shareReadOnly: Bool? = nil,
        enabled: Bool? = nil,
        before: DAVWriteSnapshot = DAVWriteSnapshot()
    ) {
        self.loginId = loginId
        self.addressBookId = addressBookId
        self.calendarId = calendarId
        self.contactId = contactId
        self.collectionHref = collectionHref
        self.href = href
        self.body = body
        self.etag = etag
        self.editedProperties = editedProperties
        self.displayName = displayName
        self.color = color
        self.sharee = sharee
        self.shareReadOnly = shareReadOnly
        self.enabled = enabled
        self.before = before
    }

    /// `later` folded into this one: later content and etag, both sets of edited
    /// properties, this one's `before` — reverting the fold reaches the state before the
    /// first edit.
    func merging(_ later: DAVWritePayload) -> DAVWritePayload {
        var merged = later
        merged.editedProperties = editedProperties + later.editedProperties.filter { !editedProperties.contains($0) }
        merged.before = before
        // The first write's precondition is the one the server can check: the later write's
        // etag, if it had one, was read from the same unchanged server copy.
        merged.etag = etag ?? later.etag
        return merged
    }
}

/// What a DAV write overwrote, for **Discard**.
public struct DAVWriteSnapshot: Codable, Sendable, Equatable {
    /// False for a create.
    public var existed: Bool
    public var body: String?
    public var etag: String?
    public var displayName: String?
    public var color: String?

    public init(
        existed: Bool = true,
        body: String? = nil,
        etag: String? = nil,
        displayName: String? = nil,
        color: String? = nil
    ) {
        self.existed = existed
        self.body = body
        self.etag = etag
        self.displayName = displayName
        self.color = color
    }
}

/// One DAV row, as the handler sees it.
public struct DAVWrite: Sendable, Equatable {
    /// The oldest `pendingOperation.id` of the (collapsed) write.
    public var operationId: Int64
    public var kind: OperationKind
    public var accountId: Int64
    public var payload: DAVWritePayload
    /// The drainer parked this row after the handler gave up on a 412: it waits for the
    /// user's **Retry now** or **Discard**, and a sync must not overwrite its href.
    public var isConflicted: Bool

    public init(
        operationId: Int64,
        kind: OperationKind,
        accountId: Int64,
        payload: DAVWritePayload,
        isConflicted: Bool = false
    ) {
        self.operationId = operationId
        self.kind = kind
        self.accountId = accountId
        self.payload = payload
        self.isConflicted = isConflicted
    }

    /// The write a queue row holds, or nil for a row of any other kind.
    public init?(record: PendingOperationRecord) {
        guard
            let id = record.id,
            let kind = OperationKind(rawValue: record.kind), kind.isDAV,
            let payload = OperationPayload.decode(record.payloadJSON).dav
        else { return nil }
        self.init(
            operationId: id,
            kind: kind,
            accountId: record.accountId,
            payload: payload,
            isConflicted: record.lastError == DAVWrite.conflictMarker
        )
    }

    /// `pendingOperation.lastError` of a parked conflict.
    public static let conflictMarker = "conflict"
}

/// Who applies, sends and reverts the DAV kinds: the contacts and calendar sync (WS-24).
///
/// The queue owns ordering, persistence, backoff and the popover; the handler owns the
/// vCard/iCalendar mapping onto the mirror's contact rows and the 412 recovery. Errors from
/// ``send(_:)`` may be `DAVError` or `MailError`; the drainer maps both.
public protocol DAVWriteHandling: Sendable {
    /// The optimistic local change, called right after the row is queued.
    func apply(_ write: DAVWrite) async throws
    /// The request, called by the drainer in queue order.
    func send(_ write: DAVWrite) async throws
    /// **Discard**: put ``DAVWritePayload/before`` back.
    func revert(_ write: DAVWrite) async
}

/// The plain `DAVClient` verbs for each DAV kind, with no recovery of its own.
///
/// A handler's ``DAVWriteHandling/send(_:)`` delegates here and wraps the 412 case.
public struct DAVWriteSender: Sendable {
    private let client: DAVClient

    public init(client: DAVClient) {
        self.client = client
    }

    /// The new ETag of a put when the server sent one; nil otherwise.
    @discardableResult
    public func send(_ write: DAVWrite) async throws -> String? {
        let payload = write.payload
        guard let href = payload.href else { throw DAVError.notFound }
        let url = client.resolve(href: href)
        switch write.kind {
        case .contactPut:
            return try await client.put(
                url,
                data: Data((payload.body ?? "").utf8),
                contentType: "text/vcard; charset=utf-8",
                ifMatch: payload.etag
            )
        case .calendarPut:
            return try await client.put(
                url,
                data: Data((payload.body ?? "").utf8),
                contentType: "text/calendar; charset=utf-8",
                ifMatch: payload.etag
            )
        case .contactDelete, .addressBookDelete:
            try await client.delete(url, ifMatch: payload.etag)
        case .addressBookCreate:
            try await client.mkcolExtended(
                url,
                resourceTypes: [DAVWriteSender.addressbook],
                properties: properties(of: payload)
            )
        case .addressBookUpdate:
            try await client.proppatch(url, set: properties(of: payload))
        case .addressBookShare:
            guard let sharee = payload.sharee else { throw DAVError.notFound }
            try await client.share(url, with: sharee, readOnly: payload.shareReadOnly ?? false)
        default:
            throw DAVError.invalidResponse("not a DAV kind")
        }
        return nil
    }

    private func properties(of payload: DAVWritePayload) -> [DAVProposedProperty] {
        var properties: [DAVProposedProperty] = []
        if let name = payload.displayName {
            properties.append(DAVProposedProperty(DAVWriteSender.displayName, name))
        }
        if let enabled = payload.enabled {
            properties.append(DAVProposedProperty(DAVWriteSender.ocEnabled, enabled ? "1" : "0"))
        }
        if let color = payload.color {
            properties.append(DAVProposedProperty(DAVWriteSender.addressBookColor, color))
        }
        return properties
    }

    static let addressbook = DAVQualifiedName.addressbook
    static let displayName = DAVQualifiedName.displayname
    static let ocEnabled = DAVQualifiedName(DAVQualifiedName.owncloud, "enabled")
    /// Nextcloud's address book colour, in the Apple iCal namespace like the calendar one.
    static let addressBookColor = DAVQualifiedName("http://apple.com/ns/ical/", "calendar-color")
}
