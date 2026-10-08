// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing

@testable import NextcloudMail

/// The message body's context menu offers nothing that loads outside the navigation
/// delegate. WebKit's **Download Linked File** sent a GET to the sender's host with no link
/// confirmation and outside the content rule list.
@Suite("Message body context menu")
@MainActor
struct MessageBodyContextMenuTests {
    private static func menu(_ identifiers: [String?]) -> NSMenu {
        let menu = NSMenu()
        for identifier in identifiers {
            guard let identifier else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            menu.addItem(item)
        }
        return menu
    }

    @Test("every item that starts a load goes; Open Link and Copy Link stay")
    func loadingItemsAreStripped() {
        // The order and separators of WebKit's link and image menus, with every loading
        // item WebKit has.
        let menu = Self.menu([
            "WKMenuItemIdentifierOpenLink",
            "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile",
            nil,
            "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage",
            nil,
            "WKMenuItemIdentifierOpenMediaInNewWindow",
            "WKMenuItemIdentifierDownloadMedia",
            "WKMenuItemIdentifierOpenFrameInNewWindow",
            nil,
            "WKMenuItemIdentifierCopyLink",
            nil,
        ])

        MessageBodyWKWebView.strip(menu)

        // A separator between the two that stay is WebKit's; the ones the removal stranded
        // are gone.
        #expect(
            menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                == ["WKMenuItemIdentifierOpenLink", "—", "WKMenuItemIdentifierCopyLink"]
        )
    }
}
