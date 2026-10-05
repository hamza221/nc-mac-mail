// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

@Suite("Subject prefixes (§6.1)")
struct SubjectPrefixTests {
    @Test(arguments: [
        ("Hello", "Re: Hello"),
        ("Re: Hello", "Re: Hello"),
        ("RE: Hello", "RE: Hello"),
        ("AW: Hallo", "AW: Hallo"),
        ("SV: Hej", "SV: Hej"),
        ("Antw: Hoi", "Antw: Hoi"),
        ("回复：你好", "回复：你好"),
        ("回复: 你好", "回复: 你好"),
        ("Re[2]: Hello", "Re[2]: Hello"),
        ("Fwd: Hello", "Re: Fwd: Hello"),
        ("WG: Hallo", "Re: WG: Hallo"),
        ("Meeting: notes", "Re: Meeting: notes"),
        ("", "Re: "),
    ])
    func reply(subject: String, expected: String) {
        #expect(SubjectPrefix.reply(subject) == expected)
    }

    @Test(arguments: [
        ("Hello", "Fwd: Hello"),
        ("Fwd: Hello", "Fwd: Hello"),
        ("FW: Hello", "FW: Hello"),
        ("WG: Hallo", "WG: Hallo"),
        ("TR: Bonjour", "TR: Bonjour"),
        ("RV: Hola", "RV: Hola"),
        ("转发: 你好", "转发: 你好"),
        ("Re: Hello", "Fwd: Re: Hello"),
        ("AW: Hallo", "Fwd: AW: Hallo"),
    ])
    func forward(subject: String, expected: String) {
        #expect(SubjectPrefix.forward(subject) == expected)
    }

    @Test func aWordWithAColonIsNotAPrefix() {
        #expect(SubjectPrefix.leadingPrefix("Project update for Q3: draft") == nil)
        #expect(SubjectPrefix.leadingPrefix("Re(abc): x") == nil)
    }
}

@Suite("Address parsing")
struct AddressParserTests {
    @Test func namedAndBareAddresses() {
        let parsed = AddressParser.parseList(
            #"Alice <alice@example.com>, "Bob, Jr." <bob@example.com>; carol@example.com"#)
        #expect(
            parsed == [
                ComposerAddress(email: "alice@example.com", label: "Alice"),
                ComposerAddress(email: "bob@example.com", label: "Bob, Jr."),
                ComposerAddress(email: "carol@example.com"),
            ])
    }

    @Test func invalidStaysInvalid() {
        #expect(!ComposerAddress(email: "not an address").isValid)
        #expect(!ComposerAddress(email: "@example.com").isValid)
        #expect(ComposerAddress(email: "a@b").isValid)
    }

    @Test func duplicatesAreCaseInsensitive() {
        let list = [
            ComposerAddress(email: "A@x.org"), ComposerAddress(email: "a@X.org"), ComposerAddress(email: "b@x.org"),
        ]
        #expect(ReplyRecipients.dedupe(list).map(\.email) == ["A@x.org", "b@x.org"])
    }
}

@Suite("Reply recipients (§6.1)")
struct ReplyRecipientsTests {
    let me: Set<String> = ["me@example.com", "alias@example.com"]
    let alice = ComposerAddress(email: "alice@example.com", label: "Alice")
    let bob = ComposerAddress(email: "bob@example.com")
    let carol = ComposerAddress(email: "carol@example.com")
    let own = ComposerAddress(email: "me@example.com")
    let list = ComposerAddress(email: "list@lists.example.com")

    private func original(
        from: [ComposerAddress], to: [ComposerAddress], cc: [ComposerAddress] = [], replyTo: [ComposerAddress] = [],
        isList: Bool = false
    ) -> ReplyRecipients.Original {
        ReplyRecipients.Original(from: from, to: to, cc: cc, replyTo: replyTo, isMailingList: isList)
    }

    @Test func replyGoesToTheSender() {
        let result = ReplyRecipients.build(original(from: [alice], to: [own, bob]), mode: .sender, own: me)
        #expect(result == .init(to: [alice], cc: []))
    }

    @Test func replyToIsHonoured() {
        let result = ReplyRecipients.build(original(from: [alice], to: [own], replyTo: [carol]), mode: .sender, own: me)
        #expect(result.to == [carol])
    }

    @Test func replyToIsIgnoredOnMailingLists() {
        let result = ReplyRecipients.build(
            original(from: [alice], to: [list], replyTo: [list], isList: true), mode: .sender, own: me)
        #expect(result.to == [alice])
    }

    @Test func replyAllRemovesMeAndKeepsCc() {
        let result = ReplyRecipients.build(
            original(from: [alice], to: [own, bob], cc: [carol, own]), mode: .all, own: me)
        #expect(result == .init(to: [alice, bob], cc: [carol]))
    }

    @Test func replyAllDoesNotRepeatToInCc() {
        let result = ReplyRecipients.build(original(from: [alice], to: [own], cc: [alice, bob]), mode: .all, own: me)
        #expect(result == .init(to: [alice], cc: [bob]))
    }

    @Test func myOwnSentMessageGoesToItsRecipients() {
        let result = ReplyRecipients.build(original(from: [own], to: [bob], cc: [carol]), mode: .all, own: me)
        #expect(result == .init(to: [bob], cc: [carol]))
    }

    @Test func selfSentGoesBackToMe() {
        let result = ReplyRecipients.build(original(from: [own], to: [own]), mode: .sender, own: me)
        #expect(result.to == [own])
    }

    @Test func followUpGoesToTheOriginalRecipients() {
        let result = ReplyRecipients.build(original(from: [own], to: [bob, carol]), mode: .followUp, own: me)
        #expect(result.to == [bob, carol])
    }
}

@Suite("mailto: parsing (§6.2)")
struct MailtoParserTests {
    @Test func everyField() throws {
        let url = try #require(
            URL(
                string:
                    "mailto:alice@example.com?cc=bob@example.com&bcc=carol@example.com&subject=Hello%20there&body=Line%201%0ALine%202"
            ))
        let fields = try #require(MailtoFields(url: url))
        #expect(fields.to == [ComposerAddress(email: "alice@example.com")])
        #expect(fields.cc == [ComposerAddress(email: "bob@example.com")])
        #expect(fields.bcc == [ComposerAddress(email: "carol@example.com")])
        #expect(fields.subject == "Hello there")
        #expect(fields.body == "Line 1\nLine 2")
        #expect(!fields.bodyIsHTML)
    }

    @Test func namedAddressesAndSeveralRecipients() throws {
        let fields = try #require(
            MailtoFields(string: "mailto:Alice%20Smith%20%3Calice@example.com%3E,bob@example.com?to=carol@example.com"))
        #expect(
            fields.to == [
                ComposerAddress(email: "alice@example.com", label: "Alice Smith"),
                ComposerAddress(email: "bob@example.com"),
                ComposerAddress(email: "carol@example.com"),
            ])
    }

    @Test func htmlBodyIsRich() throws {
        let fields = try #require(
            MailtoFields(string: "mailto:a@b.c?body=%3Cp%3EHi%20%3Cb%3Ethere%3C%2Fb%3E%3C%2Fp%3E"))
        #expect(fields.bodyIsHTML)
    }

    @Test func plusIsNotASpace() throws {
        let fields = try #require(MailtoFields(string: "mailto:a+tag@b.c?subject=1+1"))
        #expect(fields.to.first?.email == "a+tag@b.c")
        #expect(fields.subject == "1+1")
    }

    @Test func duplicatesAcrossFieldsCollapse() throws {
        let fields = try #require(MailtoFields(string: "mailto:a@b.c?cc=A@b.c&bcc=d@e.f"))
        #expect(fields.cc.isEmpty)
        #expect(fields.bcc.map(\.email) == ["d@e.f"])
    }

    @Test func notMailto() throws {
        #expect(MailtoFields(url: try #require(URL(string: "https://example.com"))) == nil)
    }
}

@Suite("Composer warnings (§6.3, §6.4)")
struct ComposerWarningTests {
    private func input(
        subject: String = "Hi", to: [ComposerAddress] = [ComposerAddress(email: "a@b.c")],
        cc: [ComposerAddress] = [], body: String = "", attachments: Int = 0, replyingTo: [ComposerAddress] = []
    ) -> ComposerWarning.Input {
        ComposerWarning.Input(
            subject: subject, to: to, cc: cc, bcc: [], bodyText: body, attachmentCount: attachments,
            replyingTo: replyingTo)
    }

    @Test func nothingToWarnAbout() {
        #expect(ComposerWarning.evaluate(input()).isEmpty)
    }

    @Test func noSubject() {
        #expect(ComposerWarning.evaluate(input(subject: "  ")) == [.noSubject])
    }

    @Test func forgottenAttachment() {
        #expect(ComposerWarning.evaluate(input(body: "See the attached report.")) == [.forgottenAttachment])
        #expect(ComposerWarning.evaluate(input(body: "Anbei die Datei")) == [.forgottenAttachment])
        #expect(ComposerWarning.evaluate(input(body: "See the attached report.", attachments: 1)).isEmpty)
    }

    @Test func keywordsInTheQuoteOrSignatureDoNotCount() {
        #expect(ComposerWarning.evaluate(input(body: "Thanks!\n> the attachment is here")).isEmpty)
        #expect(ComposerWarning.evaluate(input(body: "Thanks!\n-- \nattachments welcome")).isEmpty)
    }

    @Test func wordsContainingTheKeywordDoNotCount() {
        #expect(ComposerWarning.evaluate(input(body: "I am attachmentless and detached")).isEmpty)
    }

    @Test func emptyToWithCc() {
        #expect(ComposerWarning.evaluate(input(to: [], cc: [ComposerAddress(email: "a@b.c")])) == [.emptyTo])
        // Nothing at all is not a warning: Send is simply disabled.
        #expect(ComposerWarning.evaluate(input(to: [])).isEmpty)
    }

    @Test func noReply() {
        for email in ["noreply@shop.example", "no-reply@shop.example", "NoReply@shop.example"] {
            #expect(ComposerWarning.evaluate(input(replyingTo: [ComposerAddress(email: email)])) == [.noReply])
        }
        #expect(ComposerWarning.evaluate(input(replyingTo: [ComposerAddress(email: "reply@shop.example")])).isEmpty)
    }

    @Test func preSendWarningsAreTheBlockingOnes() {
        #expect(ComposerWarning.noSubject.isPreSend)
        #expect(ComposerWarning.forgottenAttachment.isPreSend)
        #expect(!ComposerWarning.emptyTo.isPreSend)
        #expect(!ComposerWarning.noReply.isPreSend)
    }
}

@Suite("Send later presets (§6.8)")
struct SendLaterPresetTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    @Test func tomorrow() {
        let now = date(2026, 10, 7, 16, 30)  // a Wednesday
        #expect(SendLaterPreset.tomorrowMorning.date(from: now, calendar: calendar) == date(2026, 10, 8, 9))
        #expect(SendLaterPreset.tomorrowAfternoon.date(from: now, calendar: calendar) == date(2026, 10, 8, 14))
    }

    @Test func mondayIsNextWeekOnAMonday() {
        #expect(
            SendLaterPreset.mondayMorning.date(from: date(2026, 10, 7, 10), calendar: calendar) == date(2026, 10, 12, 9)
        )
        #expect(
            SendLaterPreset.mondayMorning.date(from: date(2026, 10, 5, 8), calendar: calendar) == date(2026, 10, 12, 9))
    }

    @Test func customDefaultsToAnHourOnAFiveMinuteStep() {
        #expect(
            SendLaterPreset.customDefault(from: date(2026, 10, 7, 10, 2), calendar: calendar)
                == date(2026, 10, 7, 11, 5))
        #expect(
            SendLaterPreset.customDefault(from: date(2026, 10, 7, 10, 5), calendar: calendar)
                == date(2026, 10, 7, 11, 5))
    }
}

@Suite("Outbox items (§4.9)")
struct OutboxItemTests {
    @Test func statusFromTheServer() {
        #expect(OutboxItem.status(rawJSON: #"{"status":0}"#, failed: false) == .pending)
        #expect(OutboxItem.status(rawJSON: #"{"status":11}"#, failed: true) == .sentCopyFailed)
        #expect(OutboxItem.status(rawJSON: #"{"status":10}"#, failed: true) == .serverError)
        #expect(OutboxItem.status(rawJSON: #"{"status":13}"#, failed: true) == .notSent)
        #expect(OutboxItem.status(rawJSON: "{}", failed: true) == .notSent)
    }
}

@Suite("Shared inbox hand-off")
struct SharedInboxTests {
    @Test func takesAnItemOnceAndStagesItsFiles() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let item = inbox.appendingPathComponent("item-1")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: item.appendingPathComponent("a.txt"))
        let json = SharedInbox.Item(
            createdAt: 1, subject: "Shared", text: "Look", urls: ["https://example.com"],
            files: [.init(name: "notes.txt", mime: "text/plain", fileName: "a.txt")])
        try JSONEncoder().encode(json).write(to: item.appendingPathComponent("item.json"))

        let taken = try #require(SharedInbox.take(itemId: "item-1", inbox: inbox))
        #expect(taken.subject == "Shared")
        #expect(taken.urls == ["https://example.com"])
        #expect(taken.stagedFiles.map(\.name) == ["notes.txt"])
        let staged = try #require(taken.stagedFiles.first)
        #expect(try String(contentsOfFile: staged.path, encoding: .utf8) == "hello")
        #expect(SharedInbox.take(itemId: "item-1", inbox: inbox) == nil)
        AttachmentStaging.discard(path: staged.path)
    }

    @Test func refusesPathsOutsideTheInbox() {
        #expect(SharedInbox.take(itemId: "../etc", inbox: FileManager.default.temporaryDirectory) == nil)
        #expect(SharedInbox.take(itemId: "..", inbox: FileManager.default.temporaryDirectory) == nil)
    }
}
