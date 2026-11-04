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
/// - **Horizontal split**: two columns; the list above the message, split by a
///   ``ProportionalVSplit``.
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
                ProportionalVSplit(minimumPaneHeight: Self.minimumPaneHeight) {
                    content()
                } bottom: {
                    detail()
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

/// The list above the message, with the divider at a remembered fraction of the height.
///
/// Not `VSplitView`: that is an `NSSplitView` whose list pane took every point the window
/// grew by, so the message pane sat at its minimum — a header and the smart replies, no
/// body — on every launch and after every resize, and it gave neither pane the full width
/// while nothing was selected. Nudging the `NSSplitView` behind it did not hold: SwiftUI
/// lays its panes out again afterwards. Here both panes fill the width, the proportion holds
/// as the window resizes, and a drag sets it for next time.
struct ProportionalVSplit<Top: View, Bottom: View>: View {
    let minimumPaneHeight: CGFloat
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    /// The list's share of the height. App-wide, as Mail's own divider is.
    @AppStorage("messageList.horizontalSplitFraction") private var fraction = 0.5
    /// The fraction when the current drag began; the drag's translation is measured from it.
    @State private var dragOrigin: Double?

    var body: some View {
        GeometryReader { proxy in
            let available = max(proxy.size.height - Self.dividerHitHeight, 0)
            VStack(spacing: 0) {
                // Clipped: the panes' contents do not stay inside a fixed frame on their own,
                // and the message's subject drew over the list's last row.
                top()
                    .frame(maxWidth: .infinity)
                    .frame(height: topHeight(for: fraction, available: available))
                    .clipped()
                divider(available: available)
                bottom()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
    }

    /// The list's height, kept between the two panes' minimums; a window too short for both
    /// splits evenly.
    private func topHeight(for fraction: Double, available: CGFloat) -> CGFloat {
        guard available > 2 * minimumPaneHeight else { return available / 2 }
        return min(max(available * fraction, minimumPaneHeight), available - minimumPaneHeight)
    }

    private func divider(available: CGFloat) -> some View {
        Divider()
            .frame(maxWidth: .infinity, minHeight: Self.dividerHitHeight)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                // Global: the divider moves with the drag, so its own coordinate space would
                // shrink every translation and the divider would trail the pointer.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard available > 0 else { return }
                        let origin = dragOrigin ?? fraction
                        dragOrigin = origin
                        let height = topHeight(for: origin, available: available) + value.translation.height
                        fraction = topHeight(for: height / available, available: available) / available
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Divider between the list and the message"))
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                guard available > 0 else { return }
                let step = direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep
                fraction = topHeight(for: fraction + step, available: available) / available
            }
    }

    /// The divider's grab area: the visible line is one point, which is too thin to hit.
    /// The window's shape, like `minimumPaneHeight`, not a spacing token.
    private static var dividerHitHeight: CGFloat { 7 }
    /// How far one VoiceOver increment moves the divider.
    private static var accessibilityStep: Double { 0.05 }
}
