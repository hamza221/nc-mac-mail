// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NextcloudUI
import SwiftUI

/// The §6.5 toolbar. Plain mode shows undo/redo and the formatting toggle; rich mode shows
/// the lot. Every control carries an accessibility label — most through `MailSymbol`'s
/// mandatory `NCAccessibilityLabel`, the rest explicitly — so VoiceOver reads the whole row.
struct EditorToolbar: View {
    @Bindable var document: EditorDocument
    @Binding var showingSource: Bool
    /// The parent decides whether a confirmation dialog is needed before turning rich
    /// formatting off; the toolbar only reports the press.
    let onToggleFormatting: () -> Void

    @Environment(\.ncTheme) private var theme
    @State private var linkTarget = ""
    @State private var showingLinkEditor = false

    /// The web client's CKEditor family list, plus Default. Not the machine's font panel:
    /// outgoing mail should offer the fonts recipients actually have.
    private static let fontFamilies = [
        "Arial", "Courier New", "Georgia", "Lucida Sans Unicode", "Tahoma",
        "Times New Roman", "Trebuchet MS", "Verdana",
    ]
    private static let fontSizes = Array(9...24)

    var body: some View {
        HStack(spacing: theme.metrics.spacing.tight) {
            if document.mode == .rich {
                richControls
            }
            iconButton(.undo, help: "Undo (⌘Z)") { document.undo() }
            iconButton(.redo, help: "Redo (⇧⌘Z)") { document.redo() }
            toggleButton(.formatting, help: "Formatting", active: document.mode == .rich, action: onToggleFormatting)
        }
        .padding(theme.metrics.spacing.standard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Formatting toolbar"))
    }

    @ViewBuilder private var richControls: some View {
        headingMenu
        familyMenu
        sizeMenu
        divider

        toggleButton(.bold, help: "Bold (⌘B)", active: document.selection.isBold) { document.toggleBold() }
        toggleButton(.italic, help: "Italic (⌘I)", active: document.selection.isItalic) { document.toggleItalic() }
        toggleButton(.underline, help: "Underline (⌘U)", active: document.selection.isUnderlined) {
            document.toggleUnderline()
        }
        toggleButton(.strikethrough, help: "Strikethrough", active: document.selection.isStruck) {
            document.toggleStrikethrough()
        }
        colorControls
        toggleButton(.subscriptText, help: "Subscript", active: document.selection.script == -1) {
            document.toggleSubscript()
        }
        toggleButton(.superscriptText, help: "Superscript", active: document.selection.script == 1) {
            document.toggleSuperscript()
        }
        divider

        iconButton(.insertImage, help: "Insert image") { document.insertImageFromPanel() }
        alignmentMenu
        toggleButton(
            .directionLeftToRight, help: "Left to right", active: document.selection.direction == .leftToRight
        ) {
            document.setDirection(.leftToRight)
        }
        toggleButton(
            .directionRightToLeft, help: "Right to left", active: document.selection.direction == .rightToLeft
        ) {
            document.setDirection(.rightToLeft)
        }
        divider

        toggleButton(
            .bulletedList, help: "Bulleted list", active: document.selection.blockKind == .listItem(.unordered)
        ) {
            document.toggleList(.unordered)
        }
        toggleButton(
            .numberedList, help: "Numbered list", active: document.selection.blockKind == .listItem(.ordered)
        ) {
            document.toggleList(.ordered)
        }
        toggleButton(.blockQuote, help: "Block quote", active: document.selection.isQuoted) {
            document.toggleQuote()
        }
        divider

        linkButton
        iconButton(.clearFormatting, help: "Remove formatting") { document.removeFormatting() }
        iconButton(.findReplace, help: "Find and replace") { document.showFindAndReplace() }
        toggleButton(.sourceCode, help: "Source", active: showingSource) { showingSource.toggle() }
        divider
    }

    // MARK: - Menus

    private var headingMenu: some View {
        Menu {
            Toggle("Paragraph", isOn: binding(forHeading: nil))
            ForEach(1...3, id: \.self) { level in
                Toggle("Heading \(level)", isOn: binding(forHeading: level))
            }
        } label: {
            Text(headingTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Paragraph style")
        .accessibilityLabel(Text("Paragraph style"))
    }

    private var headingTitle: String {
        if case .heading(let level) = document.selection.blockKind { return "Heading \(level)" }
        return "Paragraph"
    }

    private func binding(forHeading level: Int?) -> Binding<Bool> {
        Binding {
            if let level { return document.selection.blockKind == .heading(level) }
            return document.selection.blockKind == .paragraph
        } set: { _ in
            document.setHeading(level)
        }
    }

    private var familyMenu: some View {
        Menu {
            Toggle("Default", isOn: familyBinding(nil))
            ForEach(Self.fontFamilies, id: \.self) { family in
                Toggle(family, isOn: familyBinding(family))
            }
        } label: {
            Text(document.selection.fontFamily ?? "Font")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Font family")
        .accessibilityLabel(Text("Font family"))
    }

    private func familyBinding(_ family: String?) -> Binding<Bool> {
        Binding {
            document.selection.fontFamily == family
        } set: { _ in
            document.setFontFamily(family)
        }
    }

    private var sizeMenu: some View {
        Menu {
            Toggle("Default", isOn: sizeBinding(nil))
            ForEach(Self.fontSizes, id: \.self) { size in
                Toggle("\(size)", isOn: sizeBinding(size))
            }
        } label: {
            Text(document.selection.fontSize.map(String.init) ?? "Size")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Font size")
        .accessibilityLabel(Text("Font size"))
    }

    private func sizeBinding(_ size: Int?) -> Binding<Bool> {
        Binding {
            document.selection.fontSize == size
        } set: { _ in
            document.setFontSize(size)
        }
    }

    private var alignmentMenu: some View {
        Menu {
            alignmentToggle("Align left", .left, symbol: .alignLeft)
            alignmentToggle("Align centre", .center, symbol: .alignCenter)
            alignmentToggle("Align right", .right, symbol: .alignRight)
            alignmentToggle("Justify", .justified, symbol: .alignJustify)
        } label: {
            alignmentSymbol.view(size: .small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Alignment")
        .accessibilityLabel(Text("Alignment"))
    }

    private var alignmentSymbol: MailSymbol {
        switch document.selection.alignment {
        case .center: .alignCenter
        case .right: .alignRight
        case .justified: .alignJustify
        default: .alignLeft
        }
    }

    private func alignmentToggle(_ title: String, _ alignment: NSTextAlignment, symbol: MailSymbol) -> some View {
        Toggle(
            title,
            isOn: Binding {
                document.selection.alignment == alignment
            } set: { _ in
                document.setAlignment(alignment)
            })
    }

    // MARK: - Colours

    @ViewBuilder private var colorControls: some View {
        ColorPicker(
            "Text colour",
            selection: Binding {
                Color(nsColor: document.selection.textColor ?? .textColor)
            } set: { color in
                document.setTextColor(NSColor(color))
            },
            supportsOpacity: false
        )
        .labelsHidden()
        .help("Text colour")
        .accessibilityLabel(Text("Text colour"))

        ColorPicker(
            "Background colour",
            selection: Binding {
                Color(nsColor: document.selection.backgroundColor ?? .textBackgroundColor)
            } set: { color in
                document.setBackgroundColor(NSColor(color))
            },
            supportsOpacity: false
        )
        .labelsHidden()
        .help("Background colour")
        .accessibilityLabel(Text("Background colour"))
    }

    // MARK: - Link

    private var linkButton: some View {
        toggleButton(.link, help: "Link (⌘K)", active: document.selection.hasLink) {
            linkTarget = ""
            showingLinkEditor = true
        }
        .popover(isPresented: $showingLinkEditor) {
            HStack(spacing: theme.metrics.spacing.standard) {
                TextField("https://…", text: $linkTarget)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel(Text("Link target"))
                    .onSubmit(applyLink)
                Button("Add link", action: applyLink)
                    .buttonStyle(.primary)
                if document.selection.hasLink {
                    Button("Remove") {
                        document.removeLink()
                        showingLinkEditor = false
                    }
                    .buttonStyle(.tertiary)
                    .accessibilityLabel(Text("Remove link"))
                }
            }
            .padding(theme.metrics.spacing.loose)
        }
    }

    private func applyLink() {
        defer { showingLinkEditor = false }
        let trimmed = linkTarget.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate) else { return }
        document.applyLink(url)
    }

    // MARK: - Pieces

    private var divider: some View {
        Divider().frame(height: theme.metrics.icon.large)
    }

    private func iconButton(_ symbol: MailSymbol, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            symbol.view(size: .small)
        }
        .buttonStyle(.icon)
        .help(help)
    }

    private func toggleButton(
        _ symbol: MailSymbol, help: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            symbol.view(size: .small)
                .padding(theme.metrics.spacing.hairline)
                .background(
                    active ? AnyShapeStyle(theme.colors.primarySurface) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: theme.metrics.radius.small))
        }
        .buttonStyle(.icon)
        .help(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
