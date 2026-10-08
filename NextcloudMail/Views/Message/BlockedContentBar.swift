// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// "This message contains remote content that was not loaded", with the ways out: this
/// message, this sender, or the sender's whole domain (§5.7).
///
/// The buttons sit beside the card rather than inside its content builder: `NCNoteCard`
/// ends with `.accessibilityElement(children: .combine)`, which makes any control inside it
/// unreachable to VoiceOver. Filed in `docs/feedback/library-feedback.md`.
struct BlockedContentBar: View {
    /// The address "Always show" trusts — the sender's, not the label beside it. Nil when the
    /// sender has none, and then there is nobody to trust and the button is not offered.
    let senderAddress: String?
    /// The sender's domain; nil hides the domain choice.
    let domain: String?
    let showImages: () -> Void
    let alwaysShow: () -> Void
    let alwaysShowDomain: () -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            NCNoteCard(
                .warning,
                title: "Remote content blocked",
                message: "This message contains remote content that was not loaded."
            )
            HStack(spacing: theme.metrics.spacing.standard) {
                Button("Show images", action: showImages)
                    .buttonStyle(.secondary)
                    .accessibilityLabel(Text("Show images in this message"))
                // Names the address, not "this sender": the trust is granted to the address
                // and lasts, and a display name can claim to be anybody.
                if let senderAddress, !senderAddress.isEmpty {
                    Button(action: alwaysShow) {
                        Text("Always show from \(senderAddress)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.tertiary)
                    .help(Text("Show remote images in every message from \(senderAddress)"))
                    .accessibilityLabel(Text("Always show images from \(senderAddress)"))
                }
                if let domain {
                    Button("Always show from \(domain)", action: alwaysShowDomain)
                        .buttonStyle(.tertiary)
                        .accessibilityLabel(Text("Always show images from \(domain)"))
                }
            }
        }
    }
}
