// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import OSLog

/// The CardDAV/CalDAV/WebDAV client, behind the same transport seam as
/// `MailClient` and holding the same credential protocol.
///
/// A value type with no mutable state, like `MailClient`, and with one
/// deliberate difference: **no automatic retry**. The contacts/calendar sync
/// engine (WS-24) owns its schedule, a multistatus is expensive to repeat on a
/// guess, and nothing here is latency-critical. See
/// `docs/architecture/networking.md#dav-ws-17`.
public struct DAVClient: Sendable {
    public let server: URL
    private let credentials: any MailCredentials
    private let transport: any MailTransport
    private let userAgent: String

    /// - Parameters:
    ///   - server: the instance root, e.g. `https://cloud.example.com`.
    ///   - credentials: login name and app password — the same values
    ///     `MailClient` signs with.
    ///   - transport: swapped for a fake in tests.
    public init(
        server: URL,
        credentials: any MailCredentials,
        transport: any MailTransport = URLSessionTransport(),
        clientVersion: String = MailClient.defaultVersion
    ) {
        self.server = server
        self.credentials = credentials
        self.transport = transport
        userAgent = "Nextcloud Mail (macOS)/\(clientVersion)"
    }

    /// `{server}/remote.php/dav/`, where discovery starts.
    public var davRoot: URL {
        server.appending(path: "remote.php/dav", directoryHint: .isDirectory)
    }

    /// A multistatus `href` (host-relative) as an absolute URL.
    public func resolve(href: String) -> URL {
        URL(string: href, relativeTo: server)?.absoluteURL
            ?? server.appending(path: href, directoryHint: .inferFromPath)
    }

    // MARK: - Core verbs

    public func propfind(
        _ url: URL,
        depth: DAVDepth,
        properties: [DAVQualifiedName]
    ) async throws -> [DAVResource] {
        let (data, _) = try await send(
            method: "PROPFIND",
            url: url,
            depth: depth,
            body: DAVRequestBody.propfind(properties)
        )
        return try DAVMultistatusParser.parse(data).responses
    }

    /// A raw REPORT, for the callers (calendar queries, future filters) whose
    /// body this client has no builder for yet.
    public func report(_ url: URL, body: Data, depth: DAVDepth = .zero) async throws -> DAVMultistatus {
        let (data, _) = try await send(method: "REPORT", url: url, depth: depth, body: body)
        return try DAVMultistatusParser.parse(data)
    }

    /// RFC 6578 `sync-collection`. Pass nil for the initial sync; pass the
    /// previous answer's token afterwards.
    ///
    /// Nextcloud answers a *truncated* sync as a 207 with an extra response for
    /// the collection itself carrying status 507 — not as an HTTP 507
    /// (measured; fixture `dav-sync-truncated.xml`). `truncated` is that mark;
    /// the caller loops with `newToken` until it clears.
    public func syncCollection(_ url: URL, token: String?) async throws -> DAVSyncChanges {
        let multistatus = try await report(url, body: DAVRequestBody.syncCollection(token: token))
        guard let newToken = multistatus.syncToken, !newToken.isEmpty else {
            throw DAVError.invalidResponse("sync-collection answered without a sync-token")
        }

        var changed: [DAVResource] = []
        var removed: [URL] = []
        var truncated = false
        let collectionPath = url.path(percentEncoded: true)
        for response in multistatus.responses {
            switch response.status {
            case 507:
                // The truncation mark on the collection itself.
                truncated = true
            case 404:
                removed.append(resolve(href: response.href))
            default:
                // sabre lists the collection itself on some answers; a member
                // is anything that is not the collection URL.
                let responsePath =
                    URL(string: response.href, relativeTo: server)?
                    .path(percentEncoded: true) ?? response.href
                if responsePath != collectionPath {
                    changed.append(response)
                }
            }
        }
        return DAVSyncChanges(changed: changed, removed: removed, newToken: newToken, truncated: truncated)
    }

    /// CardDAV multiget: etag plus the full vCard for each href, one request.
    public func addressbookMultiget(_ url: URL, hrefs: [String]) async throws -> [DAVResource] {
        try await report(url, body: DAVRequestBody.addressbookMultiget(hrefs: hrefs), depth: .one)
            .responses
    }

    /// CalDAV multiget: etag plus the full iCalendar object for each href.
    public func calendarMultiget(_ url: URL, hrefs: [String]) async throws -> [DAVResource] {
        try await report(url, body: DAVRequestBody.calendarMultiget(hrefs: hrefs), depth: .one)
            .responses
    }

    /// PUT, returning the new ETag **when the server sent one**. A present ETag
    /// is good for `If-Match` but does not prove the server stored our bytes:
    /// Nextcloud re-serves a vCard 4.0 as normalised 3.0 yet answers the md5 of
    /// the bytes we sent, against RFC 6352 §6.3.2.3 (measured). nil means
    /// "refetch before trusting the local copy".
    @discardableResult
    public func put(
        _ url: URL,
        data: Data,
        contentType: String,
        ifMatch: String? = nil
    ) async throws -> String? {
        var headers: [String: String] = ["Content-Type": contentType]
        if let ifMatch { headers["If-Match"] = ifMatch }
        let (_, response) = try await send(method: "PUT", url: url, headers: headers, body: data)
        return response.value(forHTTPHeaderField: "ETag")
    }

    public func delete(_ url: URL, ifMatch: String? = nil) async throws {
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch }
        _ = try await send(method: "DELETE", url: url, headers: headers, body: nil)
    }

    /// RFC 5689 extended MKCOL — how an addressbook or calendar is created.
    /// `resourceTypes` is `[.addressbook]` or `[.calendar]`; `d:collection` is
    /// implied. Initial properties (displayname, supported component set) ride
    /// along in the same request.
    public func mkcolExtended(
        _ url: URL,
        resourceTypes: [DAVQualifiedName],
        properties: [DAVProposedProperty] = []
    ) async throws {
        _ = try await send(
            method: "MKCOL",
            url: url,
            body: DAVRequestBody.mkcolExtended(resourceTypes: resourceTypes, properties: properties)
        )
    }

    /// PROPPATCH. The 207 answer grades each property separately; any failed
    /// property throws, because a rename that silently did not happen is the
    /// kind of bug a user reports weeks later.
    public func proppatch(
        _ url: URL,
        set: [DAVProposedProperty],
        remove: [DAVQualifiedName] = []
    ) async throws {
        let (data, _) = try await send(
            method: "PROPPATCH",
            url: url,
            body: DAVRequestBody.proppatch(set: set, remove: remove)
        )
        let multistatus = try DAVMultistatusParser.parse(data)
        for response in multistatus.responses {
            for propstat in response.propstats where !(200...299).contains(propstat.status) {
                let name = propstat.properties.keys.first?.description ?? "unknown"
                throw DAVError.propertyUpdateFailed(status: propstat.status, property: name)
            }
        }
    }

    /// Nextcloud's `oc:share` POST on an addressbook or calendar collection.
    /// `principal` is `principal:principals/users/<id>` (or a groups path).
    public func share(_ url: URL, with principal: String, readOnly: Bool = false) async throws {
        _ = try await send(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/xml; charset=utf-8"],
            body: DAVRequestBody.share(principal: principal, readOnly: readOnly)
        )
    }

    // MARK: - Principal discovery

    /// RFC 5397: who am I, as a principal URL.
    public func currentUserPrincipal() async throws -> URL {
        let resources = try await propfind(davRoot, depth: .zero, properties: [.currentUserPrincipal])
        guard let href = resources.first?.firstHref(.currentUserPrincipal) else {
            throw DAVError.invalidResponse("no current-user-principal on the DAV root")
        }
        return resolve(href: href)
    }

    /// The homes hanging off a principal: where the addressbooks and calendars
    /// live. Either can be absent — a server without the Calendar app still
    /// answers the CardDAV half.
    public func homeSets(of principal: URL) async throws -> DAVHomeSets {
        let resources = try await propfind(
            principal,
            depth: .zero,
            properties: [.addressbookHomeSet, .calendarHomeSet]
        )
        let addressbook = resources.first?.firstHref(.addressbookHomeSet).map { resolve(href: $0) }
        let calendar = resources.first?.firstHref(.calendarHomeSet).map { resolve(href: $0) }
        return DAVHomeSets(addressbookHome: addressbook, calendarHome: calendar)
    }

    /// The whole discovery, as one call: principal, then home sets.
    public func discoverHomeSets() async throws -> DAVHomeSets {
        try await homeSets(of: currentUserPrincipal())
    }

    // MARK: - Machinery

    private func send(
        method: String,
        url: URL,
        depth: DAVDepth? = nil,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.basicAuthorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Same rule as MailClient: a session cookie would drag CSRF checks in.
        request.httpShouldHandleCookies = false
        if let depth {
            request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            request.httpBody = body
            if headers["Content-Type"] == nil {
                request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as MailError {
            // The shared transport wraps connection failures in MailError;
            // unwrap so DAV callers get one error vocabulary.
            if case .transport(let underlying) = error {
                throw DAVError.transport(underlying)
            }
            throw DAVError.transport(error)
        } catch let error as DAVError {
            throw error
        } catch {
            throw DAVError.transport(error)
        }

        guard (200...299).contains(response.statusCode) || response.statusCode == 207 else {
            // Status and method only — never the URL, which carries the login.
            DAVLog.dav.debug(
                "\(method, privacy: .public) answered \(response.statusCode, privacy: .public)")
            throw DAVError.status(response.statusCode, data: data)
        }
        return (data, response)
    }
}

/// Logging for the DAV layer. The vocabulary is a verb and a status code;
/// URLs, bodies and headers never appear because hrefs carry the login name.
enum DAVLog {
    static let dav = Logger(subsystem: "com.nextcloud.mail", category: "dav")
}
