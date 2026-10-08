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
    let content: PlainTextBody
    let onLink: (URL) -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.comfortable) {
                Text(content.linkedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let signature = content.linkedSignature {
                    Divider()
                    Text(signature)
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
}

/// A plain body with its links already found.
///
/// Built off the main actor by `MessageViewModel` and carried in the presentation, so
/// `PlainTextBodyView.body` — which SwiftUI runs on the main actor, on every redraw — never
/// runs a data detector. The sender controls the text, and `NSDataDetector` is superlinear
/// on link-dense text: 760 KB of it froze the window for 9.5 s when this ran in `body`.
nonisolated struct PlainTextBody: Equatable, Sendable {
    /// How far into a body links are looked for, in UTF-16 units.
    ///
    /// Detection off the main actor stops the freeze but not the cost, and at this length
    /// the worst case measured is about a third of a second. Real mail puts its links well
    /// inside it; the text past it is still shown, just not as links.
    static let linkDetectionLimit = 100_000

    let text: String
    let signature: String?
    let linkedText: AttributedString
    /// Nil when there is no signature to draw under the divider.
    let linkedSignature: AttributedString?

    init(text: String, signature: String?) {
        self.text = text
        self.signature = signature
        linkedText = Self.linkified(text)
        linkedSignature = signature.flatMap { $0.isEmpty ? nil : Self.linkified($0) }
    }

    /// The linked strings are a function of the text, so comparing them again would only
    /// walk two copies of the same body.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.signature == rhs.signature
    }

    /// URLs and bare addresses turned into links, and nothing else changed.
    ///
    /// `NSDataDetector` rather than a regex: it is the same detector the rest of the system
    /// uses for data detection, so a link the Finder would recognise is a link here.
    static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let scanned = detectionLength(of: text)
        guard
            scanned > 0,
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return attributed }

        let searched = NSRange(location: 0, length: scanned)
        for match in detector.matches(in: text, options: [], range: searched) {
            guard let url = match.url, let range = Range(match.range, in: text) else { continue }
            guard
                let lower = AttributedString.Index(range.lowerBound, within: attributed),
                let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }

    /// The length of the prefix searched for links, in UTF-16 units.
    ///
    /// A body past ``linkDetectionLimit`` is cut at the last whitespace on or before it,
    /// not at the limit itself: a URL cut in half would still be detected, as a link to
    /// somewhere the sender never wrote. A body with no whitespace that early gets no links.
    static func detectionLength(of text: String) -> Int {
        let utf16 = text.utf16
        guard
            let limit = utf16.index(utf16.startIndex, offsetBy: linkDetectionLimit, limitedBy: utf16.endIndex),
            limit < utf16.endIndex
        else { return utf16.count }
        guard let cut = text.unicodeScalars[...limit].lastIndex(where: \.properties.isWhitespace) else { return 0 }
        return utf16.distance(from: utf16.startIndex, to: cut)
    }
}
