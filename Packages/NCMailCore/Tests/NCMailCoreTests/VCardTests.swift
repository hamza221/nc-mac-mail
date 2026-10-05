// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import Testing

@testable import NCMailCore

@Suite("vCard parsing and lossless serialisation")
struct VCardTests {
    /// The acceptance test of WS-17: parse → serialise of every recorded vCard
    /// is byte-identical modulo line folding. Sweeping the fixture directory
    /// means a newly recorded card is covered without anyone remembering to
    /// add a test.
    @Test func roundTripsEveryRecordedVCard() throws {
        let names = try FixtureBytes.allNames().filter { $0.hasSuffix(".vcf") }
        #expect(!names.isEmpty)
        for name in names {
            let original = try FixtureBytes.data(name)
            let cards = try VCardParser.parse(original)
            #expect(cards.count == 1, "fixture \(name) holds one card")
            let emitted = VCardSerializer.serialize(cards)
            #expect(
                Self.logicalLines(original) == Self.logicalLines(emitted),
                "round trip of \(name) changed bytes beyond folding"
            )
        }
    }

    /// Unfolds to logical lines so two byte streams can be compared "modulo
    /// line folding": CRLF-plus-blank joins disappear, everything else stays.
    static func logicalLines(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        return ContentLine.unfold(text)
    }

    // MARK: - Typed accessors against the recorded cards

    @Test func readsAliceTheVCard30Way() throws {
        let cards = try VCardParser.parse(try FixtureBytes.data("contact-alice.vcf"))
        let alice = try #require(cards.first)

        #expect(alice.version == "3.0")
        #expect(alice.uid == "ws17-alice-4f2a")
        #expect(alice.formattedName == "Dr. Alice Q. Vance")
        #expect(alice.nicknames == ["Al"])
        #expect(alice.title == "Principal Engineer")
        #expect(alice.organization == ["Initech GmbH", "Research", "Protocols"])
        #expect(alice.categories == ["Work", "VIP"])

        let name = try #require(alice.name)
        #expect(name.family == "Vance")
        #expect(name.given == "Alice")
        #expect(name.additional == "Quinn")
        #expect(name.prefixes == "Dr.")
        #expect(name.suffixes == "PhD")

        #expect(alice.emails.count == 3)
        let work = try #require(alice.emails.first)
        #expect(work.value == "alice.vance@initech.example")
        #expect(work.types.contains("WORK"))
        #expect(work.isPreferred)
        #expect(!alice.emails[1].isPreferred)

        #expect(alice.phones.count == 2)
        #expect(alice.phones[0].types == ["CELL"])

        #expect(alice.addresses.count == 2)
        let address = try #require(alice.addresses.first)
        #expect(address.street == "Ritterstrasse 2-3")
        #expect(address.locality == "Berlin")
        #expect(address.postalCode == "10969")
        #expect(address.country == "Germany")
        #expect(address.types == ["WORK"])

        #expect(alice.urls.first?.value == "https://initech.example/~avance")
        #expect(alice.impps.first?.value == "xmpp:alice@jabber.example")
        #expect(alice.socialProfiles.first?.value == "https://mast.example/@avance")
        #expect(alice.socialProfiles.first?.types == ["mastodon"])
        #expect(alice.related.first?.value == "urn:uuid:ws17-bob-9c1d")

        // The escaped note: \n becomes a newline, \, a comma.
        let note = try #require(alice.note)
        #expect(note.contains("Second line\nwith an escaped newline"))
        #expect(note.contains("a comma, kept."))

        let birthday = try #require(alice.birthday)
        #expect(birthday.year == 1984)
        #expect(birthday.month == 3)
        #expect(birthday.day == 14)
        #expect(alice.anniversary?.year == 2010)

        // The inline base64 photo decodes to real PNG bytes.
        let photo = try #require(alice.photo)
        let data = try #require(photo.data)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(photo.mediaType == "PNG")

        // X- properties survive as properties, not just as bytes.
        #expect(alice.property("X-MANAGER")?.rawValue == "Bob Tester")
        #expect(alice.rev == "2026-10-03T12:00:00Z")
    }

    @Test func readsBobWhomTheServerNormalised() throws {
        // bob was PUT as vCard 4.0; Nextcloud stored sabre-normalised 3.0 with
        // a folded ADR line — which makes him the unfolding test.
        let cards = try VCardParser.parse(try FixtureBytes.data("contact-bob.vcf"))
        let bob = try #require(cards.first)

        #expect(bob.version == "3.0")
        #expect(bob.formattedName == "Bob Tester")
        #expect(bob.emails.count == 2)
        #expect(bob.emails[0].isPreferred)  // EMAIL;TYPE=PREF

        // The folded ADR rejoined: Springfield was split across two lines.
        let address = try #require(bob.addresses.first)
        #expect(address.street == "1 Globex Plaza")
        #expect(address.locality == "Springfield")
        #expect(address.label == "1 Globex Plaza\nSpringfield")

        // A quoted parameter value keeps its comma.
        #expect(bob.phones.first?.types == ["voice,cell"])

        // Escaped separators in an X- property decode…
        let flag = try #require(bob.property("X-CUSTOM-FLAG"))
        #expect(flag.decodedValue() == "semi;colon,comma,escaped")
        // …and the parameter with a space survives.
        #expect(flag.parameter("X-PARAM")?.values == ["weird value"])

        // BDAY as sabre rewrote it: X-APPLE-OMIT-YEAR plus a placeholder year.
        #expect(bob.birthday?.month == 2)
        #expect(bob.birthday?.day == 14)
    }

    // MARK: - vCard 2.1 import habits

    @Test func decodesQuotedPrintableWithSoftLineBreaks() throws {
        // A 2.1-era export: QP value continued over a soft line break (the
        // trailing `=`), plus a bare TYPE token. Inline because Nextcloud can
        // never serve one — the server upgrades everything to 3.0 on PUT — and
        // the import path is exactly where these appear.
        let text = [
            "BEGIN:VCARD",
            "VERSION:2.1",
            "N:Müller;Jürgen",
            "NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8:Erste Zeile=0D=0Azweite Zeile =",
            "mit Umlauten: =C3=A4=C3=B6=C3=BC",
            "EMAIL;INTERNET:juergen@example.com",
            "END:VCARD",
        ].joined(separator: "\r\n")

        let cards = try VCardParser.parse(text)
        let card = try #require(cards.first)
        let note = try #require(card.property("NOTE"))
        #expect(note.decodedValue() == "Erste Zeile\r\nzweite Zeile mit Umlauten: äöü")
        // The bare 2.1 token counts as a type.
        #expect(card.emails.first?.types == ["INTERNET"])
    }

    // MARK: - Mutation

    @Test func editingOnePropertyLeavesEveryOtherByteAlone() throws {
        let original = try FixtureBytes.data("contact-alice.vcf")
        var card = try #require(try VCardParser.parse(original).first)

        card.setProperty("FN", to: "Dr. Alice Quinn Vance")
        let emitted = VCardSerializer.serialize(card)

        let before = Self.logicalLines(original)
        let after = Self.logicalLines(emitted)
        #expect(after.contains("FN:Dr. Alice Quinn Vance"))
        // Every line except FN is untouched.
        #expect(
            before.filter { !$0.hasPrefix("FN:") } == after.filter { !$0.hasPrefix("FN:") })
        // And the FN kept its position.
        #expect(
            before.firstIndex { $0.hasPrefix("FN:") } == after.firstIndex { $0.hasPrefix("FN:") })
    }

    @Test func editingAParsedPropertyInPlaceIsNeverDiscarded() throws {
        let original = try FixtureBytes.data("contact-alice.vcf")
        var card = try #require(try VCardParser.parse(original).first)
        let index = try #require(card.properties.firstIndex { $0.isNamed("TITLE") })
        #expect(card.properties[index].rawLine != nil)

        card.properties[index].parameters.append(DirectoryParameter(name: "LANGUAGE", values: ["en"]))

        #expect(card.properties[index].rawLine == nil)
        let after = Self.logicalLines(VCardSerializer.serialize(card))
        #expect(after.contains("TITLE;LANGUAGE=en:Principal Engineer"))
    }

    @Test func foldsLongSynthesisedLinesAtSeventyFiveOctets() {
        var card = VCard()
        card.setProperty("NOTE", to: String(repeating: "ä", count: 100))
        let emitted = String(decoding: VCardSerializer.serialize(card), as: UTF8.self)
        for line in emitted.split(whereSeparator: \.isNewline) {
            #expect(line.utf8.count <= 75, "emitted line exceeds 75 octets")
        }
        // And the fold did not tear a two-byte scalar.
        let reparsed = try? VCardParser.parse(Data(emitted.utf8)).first
        #expect(reparsed?.note == String(repeating: "ä", count: 100))
    }

    // MARK: - Structure errors

    @Test func throwsOnAnUnterminatedCard() {
        #expect(throws: DirectoryParseError.unterminated(component: "VCARD")) {
            try VCardParser.parse("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Half a card")
        }
    }

    @Test func throwsOnAnEndWithoutBegin() {
        #expect(throws: DirectoryParseError.missingBegin(expected: "VCARD")) {
            try VCardParser.parse("END:VCARD")
        }
    }
}
