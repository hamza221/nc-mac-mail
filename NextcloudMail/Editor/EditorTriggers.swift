// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One in-text trigger session: the character that opened it, the query typed since, and
/// where the caret is so a popover can anchor there
/// ([ADR-0074](../../docs/decisions/0074-editor-triggers.md)).
///
/// The editor owns detection and insertion; what the suggestions *are* comes from the
/// provider protocols below, so the editor never learns a mail type and stays upstreamable
/// ([ADR-0065](../../docs/decisions/0065-native-rich-text-editor.md)).
struct TriggerSession: Equatable {
    enum Kind: Character, Equatable {
        case emoji = ":"
        case mention = "@"
        case textBlock = "!"
        case smartPicker = "/"
    }

    var kind: Kind
    /// The trigger character through the caret, the range an accepted suggestion replaces.
    var range: NSRange
    /// What was typed after the trigger.
    var query: String
    /// Caret rectangle in the scroll view's coordinate space.
    var caretRect: CGRect
}

/// `@`: someone to mention. WS-26 implements this against the contacts mirror.
@MainActor
protocol MentionProvider: AnyObject {
    func mentionCandidates(matching query: String) async -> [MentionCandidate]
}

struct MentionCandidate: Identifiable, Hashable, Sendable {
    var displayName: String
    var email: String

    var id: String { email }
}

/// `!`: a reusable block of HTML by title. WS-27 implements this against text blocks.
@MainActor
protocol TextBlockProvider: AnyObject {
    func textBlocks(matching query: String) async -> [EditorTextBlock]
}

struct EditorTextBlock: Identifiable, Hashable, Sendable {
    var title: String
    /// Inserted through `HTMLImporter`, so a block outside the tag set degrades the same
    /// way any other import does.
    var html: String

    var id: String { title }
}

/// `/`: the Smart Picker. WS-27 implements this against the server's picker endpoints.
@MainActor
protocol SmartPickerProvider: AnyObject {
    func smartPickerLinks(matching query: String) async -> [SmartPickerLink]
}

struct SmartPickerLink: Identifiable, Hashable, Sendable {
    var title: String
    var url: URL

    var id: URL { url }
}

/// The three pluggable sources, bundled so the composer passes one value. All optional: a
/// missing provider leaves its trigger inert.
struct EditorProviders {
    var mentions: (any MentionProvider)?
    var textBlocks: (any TextBlockProvider)?
    var smartPicker: (any SmartPickerProvider)?

    init(
        mentions: (any MentionProvider)? = nil,
        textBlocks: (any TextBlockProvider)? = nil,
        smartPicker: (any SmartPickerProvider)? = nil
    ) {
        self.mentions = mentions
        self.textBlocks = textBlocks
        self.smartPicker = smartPicker
    }
}

/// A file pasted or dropped into the editor. Files are attachments, never inline content —
/// the editor reports them and inserts nothing.
enum EditorDroppedFile {
    case url(URL)
    /// Data without a file behind it: a screenshot on the pasteboard, an RTFD attachment.
    case data(Data, preferredName: String)
}
