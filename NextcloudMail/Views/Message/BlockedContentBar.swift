// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// "This message contains remote content that was not loaded", with the two ways out.
///
/// The buttons sit beside the card rather than inside its content builder: `NCNoteCard`
/// ends with `.accessibilityElement(children: .combine)`, which makes any control inside it
/// unreachable to VoiceOver. Filed in `docs/feedback/library-feedback.md`.
struct BlockedContentBar: View {
    let showImages: () -> Void
    let alwaysShow: () -> Void

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
                Button("Always show from this sender", action: alwaysShow)
                    .buttonStyle(.tertiary)
                    .accessibilityLabel(Text("Always show images from this sender"))
            }
        }
    }
}
