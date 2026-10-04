// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Where the system's requests wait for a window that can act on them.
///
/// `SystemAppDelegate` and the Services provider post here as soon as AppKit hands them a
/// URL, a Spotlight continuation or a selection — on a cold launch that is before SwiftUI has
/// built a window, so there is nobody to call `openComposer` yet. The links are kept, in
/// order, until ``SystemIntegration`` installs its handler, and are then delivered at once.
@MainActor
final class SystemEvents {
    static let shared = SystemEvents()

    private var buffer: [SystemLink] = []
    private var handler: (@MainActor (SystemLink) -> Void)?

    func post(_ link: SystemLink) {
        if let handler {
            handler(link)
        } else {
            buffer.append(link)
        }
    }

    /// Installs the handler and hands it everything that arrived before it.
    func setHandler(_ handler: @escaping @MainActor (SystemLink) -> Void) {
        self.handler = handler
        let pending = buffer
        buffer = []
        for link in pending { handler(link) }
    }
}
