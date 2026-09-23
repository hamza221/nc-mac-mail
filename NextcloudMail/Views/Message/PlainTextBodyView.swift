// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NextcloudUI
import SwiftUI

/// The other renderer, and the one most mail uses.
///
/// A plain body has no web engine, no scheme handler and no content rule list, because it
/// has no way to ask for anything. It also gets native selection, Dynamic Type and dark mode
/// for free, which is why `hasHtmlBody == false` is decided per message rather than once for
/// the app ([rendering.md](../../../docs/architecture/rendering.md)).
struct PlainTextBodyView: View {
    let text: String
    let signature: String?
    let onLink: (URL) -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.comfortable) {
                Text(Self.linkified(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let signature, !signature.isEmpty {
                    Divider()
                    Text(Self.linkified(signature))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(theme.metrics.spacing.loose)
        }
        // Every link in a message goes through the same confirmation, whichever renderer
        // drew it.
        .environment(
            \.openURL,
            OpenURLAction { url in
                onLink(url)
                return .handled
            }
        )
    }

    /// URLs and bare addresses turned into links, and nothing else changed.
    ///
    /// `NSDataDetector` rather than a regex: it is the same detector the rest of the system
    /// uses for data detection, so a link the Finder would recognise is a link here.
    static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
            !text.isEmpty
        else { return attributed }

        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: full) {
            guard let url = match.url, let range = Range(match.range, in: text) else { continue }
            guard
                let lower = AttributedString.Index(range.lowerBound, within: attributed),
                let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }
}
