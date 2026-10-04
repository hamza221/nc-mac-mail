// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// The window's shape for each `layout-mode` (ux-spec.md, WS-29).
///
/// All three share the sidebar, the list and the message — the same views, built by the
/// shell — and differ only in where the list and the message sit:
///
/// - **Vertical split**: three columns.
/// - **Horizontal split**: two columns; the list above the message in a `VSplitView`.
/// - **List**: two columns; the list full width, replaced by the opened message, which has a
///   Back button.
///
/// The selection is not in any of these views but in `MessageListStore`, so swapping one
/// shape for another keeps what was selected and the message on screen.
struct MessageListLayoutHost<Sidebar: View, Content: View, Detail: View>: View {
    let layout: MessageListLayout
    /// The message opened in the list layout; nil shows the list.
    @Binding var openedMessageId: Int64?
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        switch layout {
        case .verticalSplit:
            NavigationSplitView {
                sidebar()
            } content: {
                content()
            } detail: {
                detail()
            }
        case .horizontalSplit:
            NavigationSplitView {
                sidebar()
            } detail: {
                VSplitView {
                    content()
                        .frame(minHeight: Self.minimumPaneHeight)
                    detail()
                        .frame(minHeight: Self.minimumPaneHeight)
                }
            }
        case .list:
            NavigationSplitView {
                sidebar()
            } detail: {
                if openedMessageId != nil {
                    detail()
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button {
                                    openedMessageId = nil
                                } label: {
                                    MailSymbol.back.view(label: .text("Back to the list"))
                                }
                                .keyboardShortcut("[", modifiers: .command)
                                .help(Text("Back to the list"))
                            }
                        }
                } else {
                    content()
                }
            }
        }
    }

    /// A pane of the horizontal split never collapses below a few rows. The window's shape,
    /// not a spacing token — the same reasoning as the shell's column widths.
    private static var minimumPaneHeight: CGFloat { 160 }
}
