// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailCore

@Suite("RawBacked and AnyJSON")
struct RawBackedTests {
    @Test("rawJSON round-trips every field, including the unmodelled ones")
    func roundTripsUnmodelledFields() throws {
        let entries = try Fixture.decode([RawBacked<Envelope>].self, from: "messages-inbox-page1.json")
        let entry = try #require(entries.first)
        let reEncoded = try entry.rawJSON()
        let reDecoded = try JSONDecoder().decode(AnyJSON.self, from: reEncoded)
        #expect(reDecoded == entry.json)

        let members = try #require(reDecoded.objectValue)
        // `remoteId` and `summary` are in the payload and not in the model.
        #expect(members["remoteId"] != nil)
        #expect(members["summary"] != nil)
    }

    @Test("an integer id stays an integer through the round trip")
    func keepsIntegerFidelity() throws {
        let entries = try Fixture.decode([RawBacked<Envelope>].self, from: "messages-inbox-page1.json")
        let entry = try #require(entries.first)
        #expect(entry.json.objectValue?["databaseId"] == .int(entry.value.id))
        let text = try String(decoding: entry.rawJSON(), as: UTF8.self)
        #expect(text.contains("\"databaseId\":\(entry.value.id)"))
    }

    @Test("keys are sorted, so two recordings of one payload compare equal")
    func sortsKeys() throws {
        let stats = try Fixture.decode(RawBacked<MailboxStats>.self, from: "mailbox-stats.json")
        let text = try String(decoding: stats.rawJSON(), as: UTF8.self)
        // "total" sorts before "unread" whatever the counts were that day.
        #expect(text == #"{"total":\#(stats.value.total),"unread":\#(stats.value.unread)}"#)
    }

    @Test("AnyJSON keeps booleans and numbers apart")
    func distinguishesBooleansFromNumbers() throws {
        let data = Data(#"{"a":true,"b":1,"c":1.5,"d":null,"e":"1"}"#.utf8)
        let json = try JSONDecoder().decode(AnyJSON.self, from: data)
        let members = try #require(json.objectValue)
        #expect(members["a"] == .bool(true))
        #expect(members["b"] == .int(1))
        #expect(members["c"] == .double(1.5))
        #expect(members["d"] == .null)
        #expect(members["e"] == .string("1"))
    }
}

@Suite("MessageFlags")
struct MessageFlagsTests {
    @Test("the object form decodes")
    func decodesObject() throws {
        let data = Data(
            #"{"seen":true,"flagged":false,"$junk":false,"$notjunk":true,"$mdnsent":true}"#.utf8
        )
        let flags = try JSONDecoder().decode(MessageFlags.self, from: data)
        #expect(flags.seen)
        #expect(!flags.flagged)
        #expect(!flags.junk)
        #expect(flags.notJunk)
        #expect(flags.mdnSent)
    }

    @Test("the array form still decodes, and an unknown name is ignored")
    func decodesArray() throws {
        let data = Data(#"["\\Seen","$junk","\\Answered","\\SomethingNew"]"#.utf8)
        let flags = try JSONDecoder().decode(MessageFlags.self, from: data)
        #expect(flags.seen)
        #expect(flags.junk)
        #expect(flags.answered)
        #expect(!flags.flagged)
    }

    @Test("a missing key is false, not a decoding failure")
    func defaultsMissingKeys() throws {
        let flags = try JSONDecoder().decode(MessageFlags.self, from: Data("{}".utf8))
        #expect(flags == MessageFlags())
    }
}

@Suite("Lenient decoding")
struct LenientDecodingTests {
    private struct Probe: Decodable {
        let flag: Bool
        let role: String?
        let tags: [String: NCMailCore.Tag]

        private enum CodingKeys: String, CodingKey {
            case flag
            case role
            case tags
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            flag = try container.decodeLenientBool(forKey: .flag)
            role = try container.decodeLenientString(forKey: .role)
            tags = try container.decodePHPDictionary(NCMailCore.Tag.self, forKey: .tags)
        }
    }

    @Test(
        "a boolean survives true, 1 and \"1\"",
        arguments: ["true", "1", "\"1\""]
    )
    func decodesLenientBool(literal: String) throws {
        let probe = try JSONDecoder().decode(
            Probe.self,
            from: Data(#"{"flag":\#(literal),"role":"inbox","tags":{}}"#.utf8)
        )
        #expect(probe.flag)
    }

    @Test("the integer 0 in specialRole means no role")
    func decodesLenientString() throws {
        let probe = try JSONDecoder().decode(
            Probe.self,
            from: Data(#"{"flag":0,"role":0,"tags":[]}"#.utf8)
        )
        #expect(!probe.flag)
        #expect(probe.role == nil)
        #expect(probe.tags.isEmpty)
    }

    @Test("a genuinely wrong type still throws")
    func rejectsWrongTypes() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                Probe.self,
                from: Data(#"{"flag":{"nope":true},"role":"inbox","tags":{}}"#.utf8)
            )
        }
    }
}
