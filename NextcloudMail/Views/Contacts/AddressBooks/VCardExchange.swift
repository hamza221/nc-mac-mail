// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync

/// An address book (or a selection) as one `.vcf`, written from the mirror — so it works
/// offline and needs no `?export` request. Every card goes through ``VCardSerializer``, which
/// emits each untouched line as the server sent it; only the folding may differ.
nonisolated enum VCardExport {
    static func data(_ records: [ContactRecord]) -> Data {
        var output = Data()
        for record in records {
            if let card = try? VCardParser.parse(record.vcard).first {
                output.append(VCardSerializer.serialize(card))
            } else {
                // A card the parser refuses still belongs in the export, as stored.
                var text = record.vcard.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\r\n")
                if !text.hasSuffix("\r\n") { text += "\r\n" }
                output.append(Data(text.utf8))
            }
        }
        return output
    }

    /// `Name.vcf`, with the characters a file name cannot hold replaced.
    static func fileName(_ name: String?) -> String {
        let base = (name ?? "").components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? String(localized: "Contacts") : base) + ".vcf"
    }
}

/// A `.vcf` file read into the writes it becomes: one `contactPut` per card (ADR-0096).
///
/// A card whose UID the target book already holds overwrites that contact (so importing an
/// export back is idempotent rather than a second copy); a card without a UID gets one, as
/// does a second card repeating a UID earlier in the same file. Each new card goes to
/// `<book>/<UID>.vcf` like web Contacts, unless the UID is not safe as a file name.
nonisolated struct VCardImportPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var card: VCard
        let existing: ContactRecord?
        let href: String
    }

    let items: [Item]

    var newCount: Int { items.count { $0.existing == nil } }
    var updateCount: Int { items.count { $0.existing != nil } }

    enum Failure: Error, Equatable {
        case noCards
        case unreadable
        case badBook
    }

    static func make(
        data: Data, bookURL: String, existing: [ContactRecord],
        newUID: () -> String = { UUID().uuidString.lowercased() }
    ) throws(Failure) -> VCardImportPlan {
        let cards: [VCard]
        do {
            cards = try VCardParser.parse(data)
        } catch {
            throw .unreadable
        }
        guard !cards.isEmpty else { throw .noCards }
        let byUID = Dictionary(
            existing.compactMap { record in record.uid.map { ($0, record) } }, uniquingKeysWith: { a, _ in a })
        let takenHrefs = Set(existing.map(\.href))
        var seenUIDs: Set<String> = []
        var items: [Item] = []
        items.reserveCapacity(cards.count)
        for var card in cards {
            var uid = card.uid?.trimmingCharacters(in: .whitespaces) ?? ""
            if uid.isEmpty || seenUIDs.contains(uid) {
                uid = newUID()
                card.setProperty("UID", to: uid)
            }
            seenUIDs.insert(uid)
            if let record = byUID[uid] {
                items.append(Item(card: card, existing: record, href: record.href))
                continue
            }
            var name = isSafeFileName(uid) ? uid : newUID()
            guard var href = ContactCardActions.newHref(bookURL: bookURL, uid: name) else { throw .badBook }
            if takenHrefs.contains(href) {
                name = newUID()
                guard let fresh = ContactCardActions.newHref(bookURL: bookURL, uid: name) else { throw .badBook }
                href = fresh
            }
            items.append(Item(card: card, existing: nil, href: href))
        }
        return VCardImportPlan(items: items)
    }

    /// The payload for one item, as the queue takes it.
    static func payload(_ item: Item, loginId: Int64, addressBookId: Int64) -> DAVWritePayload {
        ContactWriteHandler.putPayload(
            loginId: loginId, addressBookId: addressBookId, existing: item.existing, card: item.card,
            newHref: item.href)
    }

    /// `urn:uuid:…` and the like would need escaping in a path; plain names go as they are.
    static func isSafeFileName(_ uid: String) -> Bool {
        uid.count <= 200
            && uid.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || "-_.@".unicodeScalars.contains(scalar))
            }
    }
}
