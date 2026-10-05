// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailStore

/// Contact photos in the `avatar` table, ahead of server avatars (ADR-0061).
///
/// A contact photo is told apart from a server answer by its shape: `AvatarFetcher` only
/// ever stores `isExternal = true` bytes or a `missing` row (the image route serves external
/// avatars only), so a row with bytes and `isExternal = false` can only have come from here.
enum ContactAvatars {
    /// A contact photo is re-stamped once it is this old, so it never ages into
    /// `AvatarFetcher`'s 30-day re-ask window.
    static let refreshAge: TimeInterval = 7 * 24 * 60 * 60

    static func isContactPhoto(_ row: AvatarRecord) -> Bool {
        !row.isExternal && !row.missing && row.data != nil
    }

    /// After a card was written (`new`) or deleted (`new` nil): its photo goes in for each of
    /// its addresses, and an address that lost the photo it used to supply is handed back.
    static func update(store: MailStore, now: Date, new: ContactRow?, previousVCard: String?) async throws {
        let newEmails = Set(new?.emails.map { $0.email.lowercased() } ?? [])
        if let photo = new?.photo {
            try await write(photo, emails: Array(newEmails), store: store, now: now)
        }
        guard let previousVCard else { return }
        let (previousPhoto, previousEmails) = ContactMapping.photoAndEmails(of: previousVCard)
        guard previousPhoto != nil else { return }
        let lost = previousEmails.filter { new?.photo == nil || !newEmails.contains($0) }
        for email in Set(lost) {
            try await release(email, store: store, now: now)
        }
    }

    /// Writes the photo for each address, unless that exact row is already there and fresh.
    static func write(_ photo: ContactPhoto, emails: [String], store: MailStore, now: Date) async throws {
        let stamp = Int64(now.timeIntervalSince1970)
        for email in Set(emails.map { $0.lowercased() }) {
            let existing = try await store.avatar(for: email)
            if let existing, isContactPhoto(existing), existing.data == photo.data,
                Double(stamp - existing.fetchedAt) < refreshAge
            {
                continue
            }
            try await store.upsert(
                avatar: AvatarRecord(
                    email: email, data: photo.data, mime: photo.mime, isExternal: false, fetchedAt: stamp))
        }
    }

    /// The address no longer has this card's photo: another enabled card's photo takes over,
    /// or the row is marked stale so `AvatarFetcher` asks the server on its next pass.
    private static func release(_ email: String, store: MailStore, now: Date) async throws {
        guard let existing = try await store.avatar(for: email), isContactPhoto(existing) else { return }
        for contact in try await store.contacts(withEmail: email) {
            if let photo = ContactMapping.photoAndEmails(of: contact.vcard).photo {
                try await write(photo, emails: [email], store: store, now: now)
                return
            }
        }
        try await store.upsert(avatar: AvatarRecord(email: email, missing: true, fetchedAt: 0))
    }
}
