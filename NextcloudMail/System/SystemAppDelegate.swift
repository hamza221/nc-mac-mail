// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreSpotlight
import OSLog

/// AppKit's doors into the app that SwiftUI's `App` has no API for, all posting a
/// ``SystemLink`` to ``SystemEvents``:
///
/// - URLs the app is asked to open — `mailto:` and `ncmail:`, registered in
///   `System/Info.plist`. Implementing `application(_:open:)` is also what stops SwiftUI
///   from opening a second main window for each URL.
/// - A Spotlight result (`CSSearchableItemActionType`).
/// - The Services menu (``SystemServicesProvider``).
final class SystemAppDelegate: NSObject, NSApplicationDelegate {
    private let services = SystemServicesProvider()
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "system")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let link = SystemLink(url: url) {
                SystemEvents.shared.post(link)
            } else {
                // The scheme only: the rest of an unknown link may be anything.
                Self.logger.info("ignored a URL with scheme \(url.scheme ?? "none", privacy: .public)")
            }
        }
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard let link = Self.link(for: userActivity) else { return false }
        SystemEvents.shared.post(link)
        return true
    }

    /// A Spotlight continuation, or a web-style activity carrying an `ncmail:` URL.
    static func link(for activity: NSUserActivity) -> SystemLink? {
        if activity.activityType == CSSearchableItemActionType,
            let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        {
            return SpotlightIdentifier.link(for: identifier)
        }
        return activity.webpageURL.flatMap(SystemLink.init(url:))
    }
}

/// Services ▸ "New Nextcloud Mail message with selection" (`NSServices` in
/// `System/Info.plist`, message `newMessageWithSelection`): the selected text becomes the
/// body of a new message.
final class SystemServicesProvider: NSObject {
    private let post: @MainActor (SystemLink) -> Void

    init(post: @escaping @MainActor (SystemLink) -> Void = { SystemEvents.shared.post($0) }) {
        self.post = post
    }

    @objc func newMessageWithSelection(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty,
            let link = SystemLink.compose(body: text)
        else {
            error.pointee = String(localized: "There is no text to put in a message.") as NSString
            return
        }
        post(link)
    }
}
