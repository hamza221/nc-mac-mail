// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog
import Sparkle

/// Which releases this Mac is offered (ADR-0108).
///
/// The appcast tags every pre-release item `<sparkle:channel>beta</sparkle:channel>` and
/// leaves stable items untagged. Sparkle always offers untagged items, so "beta" is stable
/// plus the tagged ones rather than a separate feed.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: Self { self }

    var title: String {
        switch self {
        case .stable: String(localized: "Stable")
        case .beta: String(localized: "Beta")
        }
    }

    /// The tagged Sparkle channels this channel accepts on top of the untagged default.
    var sparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: ["beta"]
        }
    }

    static let defaultsKey = "updates.channel"

    /// A pre-release build (`0.3.0-beta`) starts on the beta channel. Starting it on stable
    /// would leave everyone running a beta — today, everyone — never offered the next one.
    static func initial(forVersion version: String) -> UpdateChannel {
        version.contains("-") ? .beta : .stable
    }
}

/// The app's one Sparkle updater, and what the UI needs to know about it.
///
/// Sparkle owns the check, the download, the signature checks and the install; this type
/// only carries the channel choice in, and the "an update was found while you were busy"
/// state out, so the sidebar can say so instead of a window jumping in front of the reader.
/// Sparkle's networking does not go through `NCMailNet`: ADR-0108 records why.
@Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    /// The version a scheduled check found and Sparkle did not show, because the app was
    /// not in front at the time. Cleared once the reader has seen Sparkle's window for it.
    private(set) var pendingUpdateVersion: String?
    private(set) var lastCheckDate: Date?

    var channel: UpdateChannel {
        didSet { defaults.set(channel.rawValue, forKey: UpdateChannel.defaultsKey) }
    }

    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    private let controller: SPUStandardUpdaterController
    private let delegate: SparkleDelegate
    private let defaults: UserDefaults
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "updates")

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        channel =
            defaults.string(forKey: UpdateChannel.defaultsKey).flatMap(UpdateChannel.init(rawValue:))
            ?? .initial(forVersion: version)
        let delegate = SparkleDelegate()
        self.delegate = delegate
        // Not started here: `start()` decides whether this process should update at all.
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        delegate.owner = self
    }

    /// Starts scheduled checks. Not for a process hosting tests, and not for a Debug build:
    /// a developer's build would otherwise offer to replace itself with the last release.
    func start() {
        #if DEBUG
        Self.logger.info("updater not started: debug build")
        #else
        do {
            try controller.updater.start()
        } catch {
            Self.logger.error("updater did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        refresh()
        // KVO rather than `publisher(for:).values`: the async sequence never delivered here,
        // and the menu item stayed disabled. Sparkle is a UI-actor type, so changes arrive on
        // the main thread.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        #endif
    }

    /// A user-initiated check. Also what brings a pending update's window forward.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    fileprivate func refresh() {
        lastCheckDate = controller.updater.lastUpdateCheckDate
    }

    fileprivate func scheduledUpdateFound(version: String) {
        pendingUpdateVersion = version
    }

    fileprivate func updateSeen() {
        pendingUpdateVersion = nil
        refresh()
    }
}

/// Sparkle's two delegate protocols, on an `NSObject` the updater can be built with before
/// ``AppUpdater`` itself exists.
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var owner: AppUpdater?

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        owner?.channel.sparkleChannels ?? []
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        owner?.refresh()
    }

    // Gentle reminders: a scheduled check that lands while the reader is busy elsewhere
    // turns into a line in the sidebar instead of a window stealing focus.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            owner?.scheduledUpdateFound(version: update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        owner?.updateSeen()
    }

    func standardUserDriverWillFinishUpdateSession() {
        owner?.updateSeen()
    }
}
