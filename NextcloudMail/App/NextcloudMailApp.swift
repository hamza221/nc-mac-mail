// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// The entry point WS-13 takes over.
///
/// WS-00 owns it only so that the skeleton launches. The theme is installed
/// once here, at the scene root, which is where `NCTheme` is meant to go: it
/// sets the tint as well as the token environment, so re-applying it deeper
/// would fork the accent.
@main
struct NextcloudMailApp: App {
    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .ncTheme(.nextcloud)
        }
    }
}
