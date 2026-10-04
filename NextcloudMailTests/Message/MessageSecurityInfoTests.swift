// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import Testing

@testable import NextcloudMail

/// The banners' inputs: phishing, S/MIME, PGP, read receipt, unsubscribe, direct link.
///
/// The phishing and S/MIME JSON is the recorded `message-body.json` /
/// `message-body-attachments.json` payloads' own fields, re-serialised the way
/// `MirrorMapping` stores them — never typed in.
@Suite("Message security info")
struct MessageSecurityInfoTests {
    private static func recordedField(_ name: String, in fixture: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: try FixtureBytes.data(fixture))
        var payload = try #require(object as? [String: Any])
        if let data = payload["data"] as? [String: Any] { payload = data }
        let field = try #require(payload[name])
        return String(
            decoding: try JSONSerialization.data(withJSONObject: field, options: .fragmentsAllowed), as: UTF8.self)
    }

    @Test("the recorded phishing verdict becomes a warning with the reasons that fired")
    func recordedPhishingWarns() throws {
        let json = try Self.recordedField("phishingDetails", in: "message-body.json")
        let report = try #require(PhishingReport(json: json))
        // The recording's one firing check is the address-book one; the three quiet ones add
        // nothing.
        #expect(report.reasons.count == 1)
        #expect(report.reasons.first?.contains("is not in the address book") == true)
        #expect(report.suspiciousLinks.isEmpty)
    }

    @Test("no warning, no banner, even with a check that fired")
    func noWarningNoBanner() {
        #expect(PhishingReport(json: #"{"warning":false,"checks":[{"isPhishing":true,"message":"x"}]}"#) == nil)
        #expect(PhishingReport(json: nil) == nil)
        #expect(PhishingReport(json: "not json") == nil)
    }

    @Test("the link check's pairs are listed for Show suspicious links")
    func linkPairs() throws {
        let json = #"""
            {"warning":true,"checks":[{"type":"Link","isPhishing":true,"message":"Some addresses in this message are not matching the link text",
            "additionalData":[{"href":"https://evil.test/x","linkText":"https://bank.example"}]}]}
            """#
        let report = try #require(PhishingReport(json: json))
        #expect(report.suspiciousLinks == [.init(href: "https://evil.test/x", text: "https://bank.example")])
    }

    @Test("the recorded unsigned message has no S/MIME chip; the four states map")
    func smimeStates() throws {
        let recorded = try Self.recordedField("smime", in: "message-body.json")
        #expect(SMimeStatus(json: recorded) == nil)
        #expect(
            SMimeStatus(json: #"{"isSigned":true,"signatureIsValid":true,"isEncrypted":true}"#) == .encryptedAndVerified
        )
        #expect(SMimeStatus(json: #"{"isSigned":true,"signatureIsValid":true,"isEncrypted":false}"#) == .verified)
        #expect(SMimeStatus(json: #"{"isSigned":true,"signatureIsValid":false,"isEncrypted":false}"#) == .unverified)
        #expect(SMimeStatus(json: #"{"isSigned":false,"signatureIsValid":null,"isEncrypted":true}"#) == .encrypted)
    }

    @Test("PGP is what the server could not open, and S/MIME it did open is not PGP")
    func pgpDetection() {
        #expect(MessageSecurityInfo.isPGP(envelopeEncrypted: true, smimeEncrypted: false, plainBody: nil))
        #expect(!MessageSecurityInfo.isPGP(envelopeEncrypted: true, smimeEncrypted: true, plainBody: "Hi"))
        #expect(
            MessageSecurityInfo.isPGP(
                envelopeEncrypted: false, smimeEncrypted: false,
                plainBody: "\n-----BEGIN PGP MESSAGE-----\nhQEMA…\n-----END PGP MESSAGE-----"))
        #expect(!MessageSecurityInfo.isPGP(envelopeEncrypted: false, smimeEncrypted: false, plainBody: "Hello"))
        #expect(MessagePGPNotice.text == "This message is encrypted with PGP and can't be read in this app.")
    }

    @Test("the read receipt is requested until $mdnsent, and absent without the header")
    func readReceipt() {
        #expect(ReadReceipt(dispositionNotificationTo: "a@example.com", sent: false) == .requested)
        #expect(ReadReceipt(dispositionNotificationTo: "a@example.com", sent: true) == .sent)
        // The recording carries an empty string, which is "not asked".
        #expect(ReadReceipt(dispositionNotificationTo: "", sent: false) == nil)
        #expect(ReadReceipt(dispositionNotificationTo: nil, sent: false) == nil)
    }

    @Test("unsubscribe: one-click, link, mailto, and nothing when DKIM is known bad")
    func unsubscribeOffers() throws {
        let url = "https://lists.example/unsub?u=1"
        let parsed = try #require(URL(string: url))
        let mailto = "mailto:leave@lists.example?subject=unsubscribe"
        let parsedMailto = try #require(URL(string: mailto))
        #expect(UnsubscribeOffer(url: url, mailto: nil, isOneClick: true, dkimValid: true) == .oneClick)
        #expect(UnsubscribeOffer(url: url, mailto: nil, isOneClick: false, dkimValid: nil) == .link(parsed))
        #expect(UnsubscribeOffer(url: nil, mailto: mailto, isOneClick: false, dkimValid: nil) == .mailto(parsedMailto))
        #expect(UnsubscribeOffer(url: url, mailto: nil, isOneClick: true, dkimValid: false) == nil)
        // A `javascript:` or `file:` "URL" is not something to open.
        #expect(UnsubscribeOffer(url: "javascript:alert(1)", mailto: nil, isOneClick: false, dkimValid: true) == nil)
        #expect(UnsubscribeOffer(url: nil, mailto: nil, isOneClick: false, dkimValid: true) == nil)
    }

    @Test("the direct link keeps the Message-ID whole and percent-encodes its shape")
    func directLink() throws {
        let recorded = try Self.recordedField("messageId", in: "message-body.json")
        let decoded = try JSONSerialization.jsonObject(with: Data(recorded.utf8), options: .fragmentsAllowed)
        let messageId = try #require(decoded as? String)
        let url = try #require(MessageDirectLink.url(messageIdHeader: messageId))
        #expect(url.absoluteString == "ncmail://open/%3Cuser%40example.com%3E")
        #expect(url.host() == "open")
        #expect(
            MessageDirectLink.url(messageIdHeader: "<a/b?c#d@x>")?.absoluteString
                == "ncmail://open/%3Ca%2Fb%3Fc%23d%40x%3E")
        #expect(MessageDirectLink.url(messageIdHeader: nil) == nil)
        #expect(MessageDirectLink.url(messageIdHeader: "  ") == nil)
    }

    @Test("a reply's subject is the thread's; a changed one is shown")
    func threadSubjects() {
        #expect(!ThreadSubject.differs("Re: Fwd: Lunch", from: "Lunch"))
        #expect(!ThreadSubject.differs("FW:  lunch", from: "Lunch"))
        #expect(ThreadSubject.differs("Dinner instead", from: "Lunch"))
        #expect(!ThreadSubject.differs(nil, from: "Lunch"))
    }

    @Test("the translation banner needs 60 characters in a language not the reader's")
    func translationOffer() {
        let german =
            "Guten Morgen, wir treffen uns morgen um neun Uhr im Büro und besprechen die Planung für das nächste Quartal."
        let english =
            "Good morning, we will meet tomorrow at nine in the office and discuss the plan for the next quarter."
        let reader = Locale(identifier: "en_US")
        #expect(TranslationOffer.language(for: german, reader: reader) == reader.localizedString(forLanguageCode: "en"))
        #expect(TranslationOffer.language(for: english, reader: reader) == nil)
        #expect(TranslationOffer.language(for: "Guten Morgen", reader: reader) == nil)
    }

    @Test("smart replies read every plausible payload shape and cap at three")
    func smartReplyShapes() {
        #expect(MessageViewModel.replies(in: .array([.string("Yes"), .string(" "), .string("No")])) == ["Yes", "No"])
        #expect(MessageViewModel.replies(in: .object(["reply1": .string("A"), "reply2": .string("B")])) == ["A", "B"])
        #expect(MessageViewModel.replies(in: .object(["replies": .array([.string("A")])])) == ["A"])
        #expect(
            MessageViewModel.replies(in: .array([.string("1"), .string("2"), .string("3"), .string("4")]))?.count == 3)
        #expect(MessageViewModel.replies(in: .null) == nil)
    }
}
