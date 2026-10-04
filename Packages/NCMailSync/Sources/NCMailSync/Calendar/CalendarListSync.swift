// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailNet
public import NCMailStore
internal import OSLog

/// One calendar as the server lists it (fixture `dav-calendars-ws24.xml`).
public struct CalendarListing: Sendable, Equatable {
    public var url: String
    public var displayName: String?
    /// `#RRGGBB` or `#RRGGBBAA`, as the server stores it.
    public var color: String?
    /// `write-content` in the privilege set and no `oc:read-only`. The birthday calendar
    /// is read-only and answers no `oc:read-only` (measured).
    public var isWritable: Bool
    public var supportsEvents: Bool
    public var supportsTasks: Bool
    public var order: Int?
    public var sharedBy: String?
    /// The principal's `schedule-default-calendar-URL` names this one: where an accepted
    /// invitation lands.
    public var isDefaultSchedule: Bool

    static let properties: [DAVQualifiedName] = [
        .resourcetype, .displayname, .supportedCalendarComponentSet, .currentUserPrivilegeSet,
        MirrorDAVNames.calendarColor, MirrorDAVNames.calendarOrder,
        MirrorDAVNames.ocReadOnly, MirrorDAVNames.ocOwnerPrincipal,
    ]

    /// Calendars only: the schedule inbox/outbox and the trash bin are collections without
    /// the `calendar` resource type and drop out here.
    static func parse(
        _ resources: [DAVResource],
        client: DAVClient,
        ownPrincipalPath: String?,
        defaultScheduleURL: String?
    ) -> [CalendarListing] {
        resources.filter(\.isCalendar).map { resource in
            let url = collectionURLString(client.resolve(href: resource.href))
            let components = Set(resource.supportedCalendarComponents.map { $0.uppercased() })
            let readOnlyFlag = resource.property(MirrorDAVNames.ocReadOnly)?.text?.trimmingCharacters(in: .whitespaces)
            let flaggedReadOnly = readOnlyFlag == "1" || readOnlyFlag?.lowercased() == "true"
            let color = resource.property(MirrorDAVNames.calendarColor)?.text?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return CalendarListing(
                url: url,
                displayName: resource.displayName,
                color: color.flatMap { $0.isEmpty ? nil : $0 },
                isWritable: !flaggedReadOnly && MirrorDAVNames.canWriteContent(resource) != false,
                // RFC 4791 §5.2.3: no component set means every component.
                supportsEvents: components.isEmpty || components.contains("VEVENT"),
                supportsTasks: components.isEmpty || components.contains("VTODO"),
                order: resource.property(MirrorDAVNames.calendarOrder)?.text
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                sharedBy: MirrorDAVNames.sharedBy(resource, ownPrincipalPath: ownPrincipalPath),
                isDefaultSchedule: defaultScheduleURL == url
            )
        }
    }
}

/// The calendar list of one Nextcloud login, mirrored into `calendar`: which calendars
/// exist, what they hold (events, tasks), whether we may write them, their colour, and
/// which one is the default for scheduling. Objects inside calendars are not mirrored here.
public actor CalendarListSync {
    public static let interval: Duration = .seconds(600)

    private let store: MailStore
    private let client: DAVClient
    private let loginId: Int64
    private let now: @Sendable () -> Date

    private var conditions = MirrorConditions()
    private var homes: (principal: URL, calendarHome: URL?)?
    private var loop: Task<Void, Never>?
    private var current: Task<[CalendarListing]?, Never>?

    public init(
        store: MailStore,
        client: DAVClient,
        loginId: Int64,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.client = client
        self.loginId = loginId
        self.now = now
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.syncNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func wake() {
        Task { _ = await self.syncNow() }
    }

    public func apply(conditions newConditions: MirrorConditions) {
        let wasOffline = conditions.isOffline
        conditions = newConditions
        if wasOffline, !newConditions.isOffline { wake() }
    }

    /// A pass, or the one in flight. Nil when offline or failed; a failure replaces nothing.
    @discardableResult
    public func syncNow() async -> [CalendarListing]? {
        if let current { return await current.value }
        let task = Task { () -> [CalendarListing]? in
            do {
                return try await self.runPass()
            } catch {
                ContactsLog.calendars.error(
                    "login \(self.loginId, privacy: .public) calendar list failed: \(describeDAV(error), privacy: .public)"
                )
                return nil
            }
        }
        current = task
        let result = await task.value
        current = nil
        return result
    }

    /// One listing, written wholesale: the server owns every column of `calendar`.
    public func runPass() async throws -> [CalendarListing]? {
        guard !conditions.isOffline else { return nil }
        let homes = try await discoveredHomes()
        guard let home = homes.calendarHome else { return [] }

        let defaultScheduleURL = try await client
            .propfind(homes.principal, depth: .zero, properties: [MirrorDAVNames.scheduleDefaultCalendarURL])
            .first?.firstHref(MirrorDAVNames.scheduleDefaultCalendarURL)
            .map { collectionURLString(client.resolve(href: $0)) }
        let resources: [DAVResource]
        do {
            resources = try await client.propfind(home, depth: .one, properties: CalendarListing.properties)
        } catch DAVError.notFound {
            self.homes = nil
            throw DAVError.notFound
        }
        let listing = CalendarListing.parse(
            resources,
            client: client,
            ownPrincipalPath: homes.principal.path(percentEncoded: false),
            defaultScheduleURL: defaultScheduleURL
        )
        let fetchedAt = Int64(now().timeIntervalSince1970)
        try await store.replaceCalendars(
            listing.enumerated().map { index, calendar in
                CalendarRecord(
                    loginId: loginId,
                    url: calendar.url,
                    displayName: calendar.displayName,
                    color: calendar.color,
                    isWritable: calendar.isWritable,
                    supportsEvents: calendar.supportsEvents,
                    supportsTasks: calendar.supportsTasks,
                    isDefaultSchedule: calendar.isDefaultSchedule,
                    position: calendar.order ?? index,
                    fetchedAt: fetchedAt
                )
            },
            loginId: loginId
        )
        ContactsLog.calendars.info(
            "login \(self.loginId, privacy: .public) calendar list: \(listing.count, privacy: .public) calendars")
        return listing
    }

    private func discoveredHomes() async throws -> (principal: URL, calendarHome: URL?) {
        if let homes { return homes }
        let principal = try await client.currentUserPrincipal()
        let sets = try await client.homeSets(of: principal)
        let found = (principal: principal, calendarHome: sets.calendarHome)
        homes = found
        return found
    }
}
