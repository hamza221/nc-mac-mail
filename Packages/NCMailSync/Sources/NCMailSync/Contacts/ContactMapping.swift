// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailCore
public import NCMailStore

/// One card as the store writes it: the raw vCard and everything derived from it.
public struct ContactRow: Sendable, Equatable {
    public var record: ContactRecord
    public var emails: [ContactEmailRecord]
    public var phones: [ContactPhoneRecord]
    public var memberUids: [String]
    /// The inline photo, for the `avatar` table. A URI photo is not here: ADR-0061 forbids
    /// fetching a host the server did not vouch for.
    public var photo: ContactPhoto?
}

/// An inline vCard photo, decoded.
public struct ContactPhoto: Sendable, Equatable {
    public var data: Data
    public var mime: String?
}

/// vCard → `contact` row. The vCard text is stored as received, byte for byte; the columns
/// are a projection of it so list and sort queries never parse.
public enum ContactMapping {
    /// - Returns: nil when the text holds no parseable card. A card the parser rejects is
    ///   left out of the mirror rather than stored half-understood; the next change to it on
    ///   the server brings it back.
    public static func row(
        vcard text: String,
        href: String,
        etag: String?,
        addressBookId: Int64,
        syncedAt: Int64,
        isFavorite: Bool = false
    ) -> ContactRow? {
        guard let card = try? VCardParser.parse(text).first else { return nil }
        return row(
            card: card, text: text, href: href, etag: etag, addressBookId: addressBookId,
            syncedAt: syncedAt, isFavorite: isFavorite)
    }

    public static func row(
        card: VCard,
        text: String,
        href: String,
        etag: String?,
        addressBookId: Int64,
        syncedAt: Int64,
        isFavorite: Bool = false
    ) -> ContactRow {
        let name = card.name
        let organization = card.organization.first.flatMap(nonEmpty)
        let emails = card.emails.enumerated().compactMap { index, email -> ContactEmailRecord? in
            guard let address = nonEmpty(email.value) else { return nil }
            return ContactEmailRecord(
                contactId: 0,
                position: index,
                email: address,
                type: primaryType(email.types),
                isPreferred: email.isPreferred
            )
        }
        let phones = card.phones.enumerated().compactMap { index, phone -> ContactPhoneRecord? in
            guard let number = nonEmpty(phone.value) else { return nil }
            return ContactPhoneRecord(
                contactId: 0,
                position: index,
                number: number,
                type: primaryType(phone.types),
                isPreferred: phone.isPreferred
            )
        }
        let isGroup = kind(of: card)?.caseInsensitiveCompare("group") == .orderedSame
        let record = ContactRecord(
            addressBookId: addressBookId,
            href: href,
            etag: etag,
            uid: card.uid.flatMap(nonEmpty),
            vcard: text,
            displayName: displayName(card, organization: organization, firstEmail: emails.first?.email),
            givenName: name.flatMap { nonEmpty($0.given) },
            familyName: name.flatMap { nonEmpty($0.family) },
            nickname: card.nicknames.first.flatMap(nonEmpty),
            organization: organization,
            isGroup: isGroup,
            isFavorite: isFavorite,
            syncedAt: syncedAt
        )
        let photo = card.photo.flatMap { photo in
            photo.data.flatMap { $0.isEmpty ? nil : ContactPhoto(data: $0, mime: mimeType(photo.mediaType)) }
        }
        return ContactRow(
            record: record,
            emails: emails,
            phones: phones,
            memberUids: isGroup ? memberUids(card) : [],
            photo: photo
        )
    }

    /// The addresses and inline photo of a stored card, for avatar bookkeeping when the card
    /// changes or goes. Cheap for the common case: a card without `PHOTO` is not parsed.
    static func photoAndEmails(of vcard: String) -> (photo: ContactPhoto?, emails: [String]) {
        guard vcard.range(of: "PHOTO", options: .caseInsensitive) != nil,
            let card = try? VCardParser.parse(vcard).first
        else { return (nil, []) }
        let row = row(card: card, text: vcard, href: "", etag: nil, addressBookId: 0, syncedAt: 0)
        return (row.photo, row.emails.map { $0.email.lowercased() })
    }

    // MARK: - Projection rules

    /// FN is what every client shows; a card without one (legal in 3.0 imports) falls back to
    /// the structured name, then the organisation, then the address, so no row is blank.
    private static func displayName(_ card: VCard, organization: String?, firstEmail: String?) -> String? {
        if let formatted = card.formattedName.flatMap(nonEmpty) { return formatted }
        if let name = card.name {
            let composed = [name.prefixes, name.given, name.additional, name.family, name.suffixes]
                .compactMap(nonEmpty)
                .joined(separator: " ")
            if !composed.isEmpty { return composed }
        }
        return organization ?? firstEmail
    }

    /// vCard 4.0 `KIND`, or the Apple 3.0 spelling Nextcloud Contacts also writes.
    private static func kind(of card: VCard) -> String? {
        (card.property("KIND") ?? card.property("X-ADDRESSBOOKSERVER-KIND"))?.decodedValue()
    }

    /// `MEMBER:urn:uuid:<uid>` (4.0) or `X-ADDRESSBOOKSERVER-MEMBER` (3.0), as UIDs.
    private static func memberUids(_ card: VCard) -> [String] {
        var seen = Set<String>()
        return (card.properties("MEMBER") + card.properties("X-ADDRESSBOOKSERVER-MEMBER")).compactMap { property in
            var value = property.decodedValue().trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("urn:uuid:") { value.removeFirst("urn:uuid:".count) }
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    /// The first TYPE that says something about the value: `PREF` is its own column and
    /// `INTERNET`/`VOICE` are on every address and number.
    private static func primaryType(_ types: [String]) -> String? {
        types.first { !["PREF", "INTERNET", "VOICE", "X400"].contains($0.uppercased()) }
    }

    /// `JPEG` (3.0 TYPE) or `image/jpeg` (4.0 MEDIATYPE / data URI) → a MIME type.
    private static func mimeType(_ mediaType: String?) -> String? {
        guard let mediaType = mediaType.flatMap(nonEmpty) else { return nil }
        return mediaType.contains("/") ? mediaType.lowercased() : "image/\(mediaType.lowercased())"
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
