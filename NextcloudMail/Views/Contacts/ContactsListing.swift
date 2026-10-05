// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore

/// Web Contacts' "Sort contacts by" setting, spelled as its `orderKey`.
///
/// The web app keeps it in the browser's `localStorage` (`orderKey`, default `displayName`):
/// a per-device choice the server never sees. Here it is the same thing — a per-Mac
/// `UserDefaults` value under ``storageKey`` — so the Contacts settings row (WS-36) and this
/// list's View menu bind one key.
nonisolated enum ContactsSortOrder: String, CaseIterable, Sendable, Identifiable {
    case firstName
    case lastName
    case phoneticFirstName
    case phoneticLastName
    case displayName
    case rev

    static let storageKey = "contacts.orderKey"
    static let `default` = ContactsSortOrder.displayName

    var id: String { rawValue }

    /// The web option labels, in the web's order.
    var title: String {
        switch self {
        case .firstName: String(localized: "First name")
        case .lastName: String(localized: "Last name")
        case .phoneticFirstName: String(localized: "Phonetic first name")
        case .phoneticLastName: String(localized: "Phonetic last name")
        case .displayName: String(localized: "Display name")
        case .rev: String(localized: "Last modified")
        }
    }
}

/// One mirrored card, parsed once for what the list and the sidebar need: the name parts the
/// sort order picks from, the groups, the addresses. The record stays the source of truth.
nonisolated struct ContactEntry: Identifiable, Sendable, Equatable {
    /// Mutable so a favourite flip reuses the parse: only the vCard text forces a new one.
    var record: ContactRecord
    let id: Int64
    let formattedName: String?
    /// N: family, given (the only two the web display name reads).
    let family: String
    let given: String
    let hasName: Bool
    let organization: String?
    let phoneticFirst: String?
    let phoneticLast: String?
    let revision: Date?
    let categories: [String]
    let emails: [String]

    init?(record: ContactRecord) {
        guard let id = record.id else { return nil }
        self.record = record
        self.id = id
        let card = (try? VCardParser.parse(record.vcard))?.first
        formattedName = card?.formattedName.flatMap { $0.isEmpty ? nil : $0 } ?? record.displayName
        let name = card?.name
        family = name?.family ?? record.familyName ?? ""
        given = name?.given ?? record.givenName ?? ""
        hasName = name != nil && !(family.isEmpty && given.isEmpty)
        organization = card?.organization.first ?? record.organization
        phoneticFirst = card?.property("X-PHONETIC-FIRST-NAME")?.decodedValue()
        phoneticLast = card?.property("X-PHONETIC-LAST-NAME")?.decodedValue()
        revision = card?.rev.flatMap(Self.parseRevision)
        categories = card?.categories ?? []
        emails = card?.emails.map(\.value) ?? []
    }

    var isFavorite: Bool { record.isFavorite }

    /// The name the list shows, as web Contacts' `Contact.displayName` computes it: the sort
    /// order's name form when N has content, else FN, else N, else the organisation.
    func displayName(order: ContactsSortOrder) -> String {
        if hasName {
            switch order {
            case .firstName:
                return family.isEmpty ? given : [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            case .lastName:
                return family.isEmpty ? given : [family, given].joined(separator: ", ")
            default:
                break
            }
        }
        if let formattedName { return formattedName }
        if hasName { return family.isEmpty ? given : [given, family].filter { !$0.isEmpty }.joined(separator: " ") }
        return organization ?? ""
    }

    /// The value web Contacts sorts on for `order` (`sortedEntry`): a name field, or REV.
    func sortValue(order: ContactsSortOrder) -> SortValue {
        switch order {
        case .firstName: return .text(hasName ? given : displayName(order: order))
        case .lastName: return .text(hasName ? family : displayName(order: order))
        case .phoneticFirstName: return .text(phoneticFirst ?? (hasName ? given : displayName(order: .displayName)))
        case .phoneticLastName: return .text(phoneticLast ?? (hasName ? family : displayName(order: .displayName)))
        case .displayName: return .text(displayName(order: order))
        case .rev: return revision.map(SortValue.time) ?? .text("")
        }
    }

    enum SortValue: Sendable, Equatable {
        case text(String)
        case time(Date)
    }

    /// REV in either spelling a server writes: `20261004T120000Z` or `2026-10-04T12:00:00Z`
    /// (fractions and a date-only value tolerated). Digits only, read positionally.
    static func parseRevision(_ raw: String) -> Date? {
        let digits = raw.prefix { $0 != "." }.filter(\.isNumber).map { Int(String($0)) ?? 0 }
        guard digits.count >= 8 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= digits.count else { return nil }
            return digits[range].reduce(0) { $0 * 10 + $1 }
        }
        var components = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: number(0..<4), month: number(4..<6), day: number(6..<8))
        components.hour = number(8..<10) ?? 0
        components.minute = number(10..<12) ?? 0
        components.second = number(12..<14) ?? 0
        return components.date
    }
}

/// One CATEGORIES value across a login's cards: web Contacts' "contact group".
nonisolated struct ContactGroupSummary: Identifiable, Sendable, Equatable {
    let name: String
    let count: Int
    var id: String { name }
}

/// The pure part of the Contacts list: what a scope contains, in what order, and the groups.
nonisolated enum ContactsListing {
    /// The server-generated "Recently contacted" book (the `contactsinteraction` app).
    static func isRecentlyContacted(_ book: AddressBookRecord) -> Bool {
        book.url.contains("z-app-generated--contactsinteraction--recent")
    }

    /// The entries one sidebar scope shows, favourites first and then by `order`, filtered to
    /// `matching` when a search is running. `KIND:group` cards are not people and, as in web
    /// Contacts, are not listed.
    static func rows(
        _ entries: [ContactEntry],
        scope: ContactsScope,
        recentBookIds: Set<Int64>,
        matching: Set<Int64>?,
        order: ContactsSortOrder
    ) -> [ContactEntry] {
        let scoped = entries.filter { entry in
            guard !entry.record.isGroup else { return false }
            if let matching, !matching.contains(entry.id) { return false }
            switch scope {
            case .all: return true
            case .favorites: return entry.isFavorite
            case .addressBook(let id): return entry.record.addressBookId == id
            case .group(let name): return entry.categories.contains(name)
            case .recent: return recentBookIds.contains(entry.record.addressBookId)
            // A team's members are not cards: `TeamScopeOverlay` shows the team instead.
            case .team: return false
            }
        }
        return sorted(scoped, order: order)
    }

    /// Web Contacts' `sortByFavoriteAndData`: favourites first; then empty values last,
    /// times before text, times newest first, text by case-insensitive locale compare; the
    /// id breaks ties so the order is total.
    static func sorted(_ entries: [ContactEntry], order: ContactsSortOrder) -> [ContactEntry] {
        let keyed = entries.map { ($0, $0.sortValue(order: order)) }
        return keyed.sorted { lhs, rhs in
            if lhs.0.isFavorite != rhs.0.isFavorite { return lhs.0.isFavorite }
            let lhsEmpty = lhs.1 == .text("")
            let rhsEmpty = rhs.1 == .text("")
            if lhsEmpty != rhsEmpty { return rhsEmpty }
            switch (lhs.1, rhs.1) {
            case (.time(let a), .time(let b)):
                if a != b { return a > b }
            case (.time, .text):
                return true
            case (.text, .time):
                return false
            case (.text(let a), .text(let b)):
                let result = a.uppercased().localizedCompare(b.uppercased())
                if result != .orderedSame { return result == .orderedAscending }
            }
            return lhs.0.id < rhs.0.id
        }.map(\.0)
    }

    /// Every CATEGORIES value with how many people carry it, in natural case-insensitive
    /// order as web Contacts' navigation lists them.
    static func groups(_ entries: [ContactEntry]) -> [ContactGroupSummary] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.record.isGroup {
            for name in Set(entry.categories) { counts[name, default: 0] += 1 }
        }
        return counts.map { ContactGroupSummary(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
