// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// Three empty columns, so that M0 is an application rather than a build log.
///
/// WS-07 fills the sidebar, WS-08 the list, WS-09 the detail, and WS-13
/// replaces this file with the real shell. Nothing here reads a database or a
/// network, and nothing here should grow until one of those workstreams lands.
struct RootSplitView: View {
    var body: some View {
        NavigationSplitView {
            PlaceholderColumn(title: "Mailboxes")
        } content: {
            PlaceholderColumn(title: "Messages")
        } detail: {
            PlaceholderColumn(title: "Message")
        }
    }
}

private struct PlaceholderColumn: View {
    @Environment(\.ncTheme) private var theme

    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(theme.colors.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
