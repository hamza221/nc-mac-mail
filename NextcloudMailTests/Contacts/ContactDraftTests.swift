// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import Testing

@testable import NextcloudMail

/// The editor's write-back: what changed is rewritten, nothing else moves (ADR-0075).
@Suite("Contact editor draft")
struct ContactDraftTests {
    /// A card as other clients write it: grouped Apple labels, an unknown X- property, a
    /// 2.1-style bare type, a quoted-printable note, and a property this app does not model.
    static let foreign = """
        BEGIN:VCARD\r
        VERSION:3.0\r
        PRODID:-//Apple Inc.//Mac OS X 10.15//EN\r
        UID:ws35-draft\r
        FN:Lorelai Gilmore\r
        N:Gilmore;Lorelai;Victoria;;\r
        ORG:Dragonfly Inn;Front desk\r
        TITLE:Owner\r
        item1.EMAIL;TYPE=INTERNET,WORK,pref:lorelai@dragonfly.example\r
        item1.X-ABLabel:_$!<Work>!$_\r
        EMAIL;TYPE=HOME:lorelai@home.example\r
        TEL;CELL:+1 555 0100\r
        ADR;TYPE=HOME:;;37 Maple St;Stars Hollow;CT;06001;USA\r
        X-SOCIALPROFILE;TYPE=mastodon:https://social.example/@lorelai\r
        CATEGORIES:Family,Inn\r
        BDAY:1968-04-25\r
        X-MS-OL-DESIGN;CHARSET=utf-8:<card xmlns="http://schemas.microsoft.com/office/outlook/12/electronicbusinesscards"/>\r
        GEO:41.56;-72.95\r
        NOTE:Coffee\\, always.\r
        REV:2024-01-01T00:00:00Z\r
        END:VCARD\r

        """

    private func parse(_ text: String) throws -> VCard {
        try #require(try VCardParser.parse(text).first)
    }

    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func readsEveryTypedProperty() throws {
        let draft = ContactDraft(card: try parse(Self.foreign))
        #expect(draft.formattedName == "Lorelai Gilmore")
        #expect(draft.given == "Lorelai" && draft.family == "Gilmore" && draft.additional == "Victoria")
        #expect(draft.organization == "Dragonfly Inn" && draft.department == "Front desk")
        #expect(draft.title == "Owner")
        #expect(draft.fields(.email).map(\.value) == ["lorelai@dragonfly.example", "lorelai@home.example"])
        #expect(draft.fields(.email).first?.type == "WORK")
        #expect(draft.fields(.phone).first?.type == "CELL")
        #expect(draft.fields(.address).first?.address[2] == "37 Maple St")
        #expect(draft.fields(.social).first?.type == "MASTODON")
        #expect(draft.categories == ["Family", "Inn"])
        #expect(draft.birthday == "1968-04-25")
        #expect(draft.note == "Coffee, always.")
        #expect(draft.otherProperties.map(\.name) == ["X-ABLabel", "X-MS-OL-DESIGN", "GEO"])
        #expect(!draft.hasChanges)
    }

    /// The brief's report question: an edit leaves every other property byte for byte.
    @Test func anEditKeepsOtherPropertiesAndUntouchedLinesVerbatim() throws {
        let card = try parse(Self.foreign)
        var draft = ContactDraft(card: card)
        draft.title = "Owner, Dragonfly Inn"
        let saved = draft.card(now: Self.now)
        let text = String(decoding: VCardSerializer.serialize(saved), as: UTF8.self)

        #expect(text.contains("TITLE:Owner\\, Dragonfly Inn\r\n"))
        for line in [
            "PRODID:-//Apple Inc.//Mac OS X 10.15//EN", "item1.EMAIL;TYPE=INTERNET,WORK,pref:lorelai@dragonfly.example",
            "item1.X-ABLabel:_$!<Work>!$_", "TEL;CELL:+1 555 0100",
            "X-SOCIALPROFILE;TYPE=mastodon:https://social.example/@lorelai",
            "GEO:41.56;-72.95", "NOTE:Coffee\\, always.", "CATEGORIES:Family,Inn",
        ] {
            #expect(text.contains(line + "\r\n"), "\(line) changed")
        }
        #expect(text.contains("X-MS-OL-DESIGN;CHARSET=utf-8:"))
        #expect(text.contains("REV:20261003T"))
        // Same properties in the same order, REV aside.
        let names = { (card: VCard) in card.properties.map(\.name).filter { $0 != "REV" } }
        #expect(names(saved) == names(card))
    }

    @Test func aChangedRowKeepsItsGroupAndOtherParameters() throws {
        var draft = ContactDraft(card: try parse(Self.foreign))
        let index = try #require(draft.fields.firstIndex { $0.value == "lorelai@dragonfly.example" })
        draft.fields[index].value = "lorelai@dragonfly-inn.example"
        let saved = draft.card(now: Self.now)
        let email = try #require(saved.properties.first { $0.isNamed("EMAIL") })
        #expect(email.group == "item1")
        #expect(email.decodedValue() == "lorelai@dragonfly-inn.example")
        #expect(email.parameterValues("TYPE") == ["WORK", "pref"])
        #expect(saved.emails.first?.isPreferred == true)
    }

    @Test func addRemoveAndRetypeRows() throws {
        var draft = ContactDraft(card: try parse(Self.foreign))
        draft.fields.removeAll { $0.value == "lorelai@home.example" }
        draft.fields.append(.init(kind: .phone, type: "WORK", value: "+1 555 0199"))
        let phone = try #require(draft.fields.firstIndex { $0.kind == .phone && $0.source != nil })
        draft.fields[phone].type = "HOME"
        draft.fields.append(.init(kind: .url, type: "WORK", value: "https://dragonfly.example/a,b"))
        let saved = draft.card(now: Self.now)

        #expect(saved.emails.map(\.value) == ["lorelai@dragonfly.example"])
        #expect(saved.phones.map(\.value) == ["+1 555 0100", "+1 555 0199"])
        #expect(saved.phones.first?.types == ["HOME"])
        // URI values are written verbatim, not text-escaped.
        #expect(saved.properties("URL").first?.rawValue == "https://dragonfly.example/a,b")
    }

    @Test func structuredValuesAreEscaped() throws {
        var draft = ContactDraft(card: try parse(Self.foreign))
        let index = try #require(draft.fields.firstIndex { $0.kind == .address })
        draft.fields[index].address[2] = "37 Maple St; Apt 2"
        draft.family = "Gilmore, Jr"
        draft.categories = ["Family", "Inn", "Stars Hollow, CT"]
        let saved = draft.card(now: Self.now)
        #expect(saved.addresses.first?.street == "37 Maple St; Apt 2")
        #expect(saved.name?.family == "Gilmore, Jr")
        #expect(saved.categories == ["Family", "Inn", "Stars Hollow, CT"])
        #expect(saved.properties("CATEGORIES").count == 1)
    }

    @Test func clearingAFieldRemovesTheProperty() throws {
        var draft = ContactDraft(card: try parse(Self.foreign))
        draft.title = ""
        draft.birthday = ""
        draft.categories = []
        let saved = draft.card(now: Self.now)
        #expect(saved.property("TITLE") == nil)
        #expect(saved.property("BDAY") == nil)
        #expect(saved.property("CATEGORIES") == nil)
    }

    @Test func photoSetAndRemoveIn3And4() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        var three = ContactDraft(card: try parse(Self.foreign))
        three.photo = .set(bytes, subtype: "jpeg")
        let saved3 = three.card(now: Self.now)
        let photo3 = try #require(saved3.property("PHOTO"))
        #expect(photo3.parameterValues("ENCODING") == ["b"])
        #expect(saved3.photo?.data == bytes)

        let v4 = try parse(Self.foreign.replacingOccurrences(of: "VERSION:3.0", with: "VERSION:4.0"))
        var four = ContactDraft(card: v4)
        four.photo = .set(bytes, subtype: "jpeg")
        let saved4 = four.card(now: Self.now)
        #expect(saved4.property("PHOTO")?.rawValue.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(saved4.photo?.data == bytes)

        var removed = ContactDraft(card: saved3)
        removed.photo = .removed
        #expect(removed.card(now: Self.now).property("PHOTO") == nil)
    }

    @Test func aNewCardHasUIDNameAndTheScopeGroup() throws {
        var draft = ContactDraft.new(uid: "new-uid", categories: ["Inn"])
        draft.given = "Sookie"
        draft.family = "St. James"
        let saved = draft.card(now: Self.now)
        #expect(saved.uid == "new-uid")
        #expect(saved.formattedName == "Sookie St. James")
        #expect(saved.name?.given == "Sookie")
        #expect(saved.categories == ["Inn"])
        #expect(saved.version == "3.0")
    }

    @Test func revisionIsUTCBasicFormat() {
        #expect(ContactDraft.revision(Date(timeIntervalSince1970: 0)) == "19700101T000000Z")
    }
}
