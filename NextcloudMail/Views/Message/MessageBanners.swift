// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NaturalLanguage
import NextcloudUI
import SwiftUI

/// The banners between the header and the body, in the order
/// [ux-spec.md](../../../docs/product/ux-spec.md#message-view-v2-ws-30) lists them, each one
/// only when it applies.
///
/// Buttons sit beside each `NCNoteCard` rather than inside it: the card ends with
/// `.accessibilityElement(children: .combine)`, which makes a control inside it unreachable
/// to VoiceOver (filed in library-feedback.md by WS-09).
struct MessageBanners: View {
    let model: MessageViewModel
    let unsubscribe: (UnsubscribeOffer) -> Void
    let translate: () -> Void

    @Environment(\.ncTheme) private var theme
    @State private var showsSuspiciousLinks = false
    /// "Ignore" on a read receipt hides it for this sitting only; the request stays honest
    /// the next time the message is opened, as on the web.
    @State private var ignoredReceipt: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            if let phishing = model.security.phishing { phishingBanner(phishing) }
            if model.security.smime == .unverified {
                NCNoteCard(
                    .error,
                    message: "This message has an invalid signature. The sender might be impersonating someone!"
                )
            }
            if model.security.isPGP {
                NCNoteCard(.info) { Text(MessagePGPNotice.text) }
            }
            readReceipt
            followUp
            if let offer = model.security.unsubscribe {
                Button {
                    unsubscribe(offer)
                } label: {
                    Label {
                        Text("Unsubscribe")
                    } icon: {
                        MailSymbol.unsubscribe.view(size: .small, label: .decorative)
                    }
                }
                .buttonStyle(.tertiary)
                .help("Unsubscribe from this mailing list")
            }
            if model.hasBlockedRemoteContent, !model.showsRemoteImages, !model.isSenderTrusted {
                BlockedContentBar(
                    domain: model.senderDomain,
                    showImages: model.showImages,
                    alwaysShow: { Task { await model.alwaysShowFromThisSender() } },
                    alwaysShowDomain: { Task { await model.trustSenderDomain() } }
                )
            }
            translationBanner
        }
    }

    // MARK: - Phishing

    private func phishingBanner(_ report: PhishingReport) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            NCNoteCard(.error, title: "This email might be a phishing attempt") {
                ForEach(report.reasons, id: \.self) { reason in
                    Text(verbatim: reason)
                }
            }
            if !report.suspiciousLinks.isEmpty {
                Button(showsSuspiciousLinks ? "Hide suspicious links" : "Show suspicious links") {
                    showsSuspiciousLinks.toggle()
                }
                .buttonStyle(.tertiary)
                if showsSuspiciousLinks {
                    ForEach(report.suspiciousLinks, id: \.self) { link in
                        VStack(alignment: .leading) {
                            Text("Link text: \(link.text)").font(.caption)
                            Text("Goes to: \(link.href)").font(.caption).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Read receipt

    @ViewBuilder
    private var readReceipt: some View {
        switch model.security.readReceipt {
        case .requested? where ignoredReceipt != model.expandedId:
            VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
                NCNoteCard(
                    .info,
                    message: "The sender of this message has asked to be notified when you read this message."
                )
                HStack(spacing: theme.metrics.spacing.standard) {
                    Button {
                        Task { await model.sendReadReceipt() }
                    } label: {
                        Label {
                            Text("Notify the sender")
                        } icon: {
                            MailSymbol.readReceipt.view(size: .small, label: .decorative)
                        }
                    }
                    .buttonStyle(.secondary)
                    Button("Ignore") { ignoredReceipt = model.expandedId }
                        .buttonStyle(.tertiary)
                }
            }
        case .sent?:
            Text("You sent a read confirmation to the sender of this message.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Follow-up

    @ViewBuilder
    private var followUp: some View {
        if model.showsFollowUpBanner, let header = model.header {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
                NCNoteCard(.info) {
                    Text("You've sent this message on \(header.sentAt.formatted(date: .long, time: .omitted))")
                }
                Button("Disable reminder") { Task { await model.disableFollowUpReminder() } }
                    .buttonStyle(.tertiary)
            }
        }
    }

    // MARK: - Translation

    @ViewBuilder
    private var translationBanner: some View {
        if model.offersTranslation, let language = model.translationOfferLanguage {
            HStack(spacing: theme.metrics.spacing.standard) {
                NCNoteCard(.info) {
                    Text("Translate this message to \(language)")
                }
                Button(action: translate) {
                    Label {
                        Text("Translate")
                    } icon: {
                        MailSymbol.translate.view(size: .small, label: .decorative)
                    }
                }
                .buttonStyle(.secondary)
            }
        }
    }
}

/// When to offer a translation: enough text to judge (the web's 60 characters), and the
/// on-device recogniser says it is not the reader's language. Detection is local, so the
/// banner costs no request; the translation itself is a `serverResult`.
enum TranslationOffer {
    static let minimumLength = 60

    /// The reader's language's name, when the text is in another one; nil otherwise.
    static func language(for text: String?, reader: Locale = .current) -> String? {
        guard let text, text.count >= minimumLength,
            let readerCode = reader.language.languageCode?.identifier
        else { return nil }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(String(text.prefix(2_000)))
        guard let detected = recogniser.dominantLanguage, detected != .undetermined else { return nil }
        let detectedCode = Locale.Language(identifier: detected.rawValue).languageCode?.identifier
        guard let detectedCode, detectedCode != readerCode else { return nil }
        return reader.localizedString(forLanguageCode: readerCode) ?? readerCode
    }
}
