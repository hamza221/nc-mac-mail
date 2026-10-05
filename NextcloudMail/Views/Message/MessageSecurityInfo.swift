// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore

/// What the message view says about a body beyond the body itself: phishing, S/MIME, PGP,
/// the read receipt and the unsubscribe offer.
///
/// Parsed once per body from the columns the backfill wrote (`phishingJSON`, `smimeJSON`,
/// …), never fetched. Every input is server JSON about attacker-controlled mail, so every
/// field is optional and a shape this does not recognise reads as "nothing to say" rather
/// than as an error.
struct MessageSecurityInfo: Equatable {
    var phishing: PhishingReport?
    var smime: SMimeStatus?
    var isPGP: Bool
    var readReceipt: ReadReceipt?
    var unsubscribe: UnsubscribeOffer?
    var hasAIContent: Bool

    static let none = MessageSecurityInfo(isPGP: false, hasAIContent: false)

    init(
        phishing: PhishingReport? = nil,
        smime: SMimeStatus? = nil,
        isPGP: Bool,
        readReceipt: ReadReceipt? = nil,
        unsubscribe: UnsubscribeOffer? = nil,
        hasAIContent: Bool
    ) {
        self.phishing = phishing
        self.smime = smime
        self.isPGP = isPGP
        self.readReceipt = readReceipt
        self.unsubscribe = unsubscribe
        self.hasAIContent = hasAIContent
    }

    /// - Parameters:
    ///   - envelopeEncrypted: `message.isEncrypted`, the envelope's `encrypted` flag.
    ///   - mdnSent: `message.isMdnSent`.
    init(body: MessageBodyRecord, envelopeEncrypted: Bool, mdnSent: Bool) {
        phishing = PhishingReport(json: body.phishingJSON)
        smime = SMimeStatus(json: body.smimeJSON)
        isPGP = Self.isPGP(
            envelopeEncrypted: envelopeEncrypted,
            smimeEncrypted: smime?.isEncrypted ?? false,
            plainBody: body.hasHtmlBody ? nil : body.plainBody
        )
        readReceipt = ReadReceipt(dispositionNotificationTo: body.dispositionNotificationTo, sent: mdnSent)
        unsubscribe = UnsubscribeOffer(
            url: body.unsubscribeUrl,
            mailto: body.unsubscribeMailto,
            isOneClick: body.isOneClickUnsubscribe,
            dkimValid: body.dkimValid
        )
        hasAIContent = body.hasAiGeneratedHeader
    }

    /// PGP is what the server could not open: the envelope says encrypted and S/MIME did not
    /// decrypt it, or the plain body is an inline-armoured block. Either way the app shows the
    /// notice and nothing else (ADR-0064).
    static func isPGP(envelopeEncrypted: Bool, smimeEncrypted: Bool, plainBody: String?) -> Bool {
        if envelopeEncrypted, !smimeEncrypted { return true }
        guard let plainBody else { return false }
        return plainBody.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-----BEGIN PGP MESSAGE-----")
    }
}

/// ADR-0064's notice, verbatim, in one place: the pane shows it and the printout prints it.
enum MessagePGPNotice {
    static var text: String { String(localized: "This message is encrypted with PGP and can't be read in this app.") }
}

/// `phishingDetails`: `{"warning": Bool, "checks": [{"type", "isPhishing", "message",
/// "additionalData"}]}`, as recorded in `message-body.json`.
struct PhishingReport: Equatable {
    /// The message of every check that fired, in the server's order, empty ones dropped.
    var reasons: [String]
    /// The link check's `additionalData`: what the anchor said and where it went.
    var suspiciousLinks: [SuspiciousLink]

    struct SuspiciousLink: Equatable, Hashable {
        var href: String
        var text: String
    }

    /// Nil unless the server's overall verdict is a warning: a check that fired without the
    /// warning is the server's own judgement that it is not worth a banner.
    init?(json: String?) {
        guard let json, let object = Self.object(json), object["warning"] as? Bool == true else { return nil }
        var reasons: [String] = []
        var links: [SuspiciousLink] = []
        for check in object["checks"] as? [[String: Any]] ?? [] where check["isPhishing"] as? Bool == true {
            if let message = check["message"] as? String, !message.isEmpty { reasons.append(message) }
            for entry in check["additionalData"] as? [[String: Any]] ?? [] {
                guard let href = entry["href"] as? String else { continue }
                links.append(SuspiciousLink(href: href, text: entry["linkText"] as? String ?? ""))
            }
        }
        self.reasons = reasons
        self.suspiciousLinks = links
    }

    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}

/// `smime`: `{"isSigned", "signatureIsValid", "isEncrypted"}`. Nil for mail that is neither
/// signed nor encrypted: a chip on every message teaches people to ignore chips.
enum SMimeStatus: Equatable {
    case encryptedAndVerified
    case encrypted
    case verified
    case unverified

    init?(json: String?) {
        guard
            let json,
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        let signed = object["isSigned"] as? Bool ?? false
        let valid = object["signatureIsValid"] as? Bool
        let encrypted = object["isEncrypted"] as? Bool ?? false
        switch (signed, valid, encrypted) {
        case (true, false?, _): self = .unverified
        case (true, true?, true): self = .encryptedAndVerified
        case (true, true?, false): self = .verified
        // Signed with no verdict yet says nothing either way.
        case (_, _, true): self = .encrypted
        default: return nil
        }
    }

    var isEncrypted: Bool { self == .encrypted || self == .encryptedAndVerified }

    var label: String {
        switch self {
        case .encryptedAndVerified: String(localized: "Encrypted & verified")
        case .encrypted: String(localized: "Encrypted")
        case .verified: String(localized: "Signature verified")
        case .unverified: String(localized: "Signature unverified")
        }
    }
}

/// The read receipt the sender asked for (`Disposition-Notification-To`), and whether this
/// reader already sent it (`$mdnsent`).
enum ReadReceipt: Equatable {
    case requested
    case sent

    init?(dispositionNotificationTo: String?, sent: Bool) {
        guard let to = dispositionNotificationTo, !to.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        self = sent ? .sent : .requested
    }
}

/// What "Unsubscribe" does for this message (`List-Unsubscribe`, RFC 2369 / RFC 8058).
///
/// The web client offers it only with a valid DKIM signature. The mirror never knows that —
/// `dkimValid` is null until the separate DKIM call runs, and the backfill does not run it —
/// so the native rule is "not known bad": a signature the server *did* reject hides the
/// offer, an unverified one does not.
enum UnsubscribeOffer: Equatable {
    /// RFC 8058: the server posts to the URL for us, through the queue.
    case oneClick
    /// A web page the reader finishes the unsubscription on, in the browser.
    case link(URL)
    /// An email to send, which the composer drafts.
    case mailto(URL)

    init?(url: String?, mailto: String?, isOneClick: Bool, dkimValid: Bool?) {
        guard dkimValid != false else { return nil }
        if let url, let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? "") {
            self = isOneClick ? .oneClick : .link(parsed)
            return
        }
        if let mailto {
            let text = mailto.lowercased().hasPrefix("mailto:") ? mailto : "mailto:\(mailto)"
            if let parsed = URL(string: text), parsed.scheme?.lowercased() == "mailto" {
                self = .mailto(parsed)
                return
            }
        }
        return nil
    }
}

/// `ncmail://open/<Message-ID>`, the native spelling of the web's
/// `/apps/mail/open/<Message-ID>` (WS-42 resolves it). The Message-ID is kept whole, angle
/// brackets included, because that is the form the server matches on; everything outside
/// RFC 3986's unreserved set is percent-encoded so `/`, `?` and `#` in an id cannot change
/// the URL's shape.
enum MessageDirectLink {
    static func url(messageIdHeader: String?) -> URL? {
        guard let id = messageIdHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "ncmail://open/\(encoded)")
    }
}

/// Thread subjects compare without their reply and forward prefixes, so a collapsed
/// envelope repeats its subject only when it says something the thread's does not.
enum ThreadSubject {
    static func normalised(_ subject: String?) -> String {
        var text = (subject ?? "").trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: #"^(re|fwd|fw)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return text.lowercased()
    }

    static func differs(_ subject: String?, from thread: String?) -> Bool {
        normalised(subject) != normalised(thread) && !(subject ?? "").isEmpty
    }
}
