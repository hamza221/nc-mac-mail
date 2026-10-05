// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import OSLog
import SwiftUI

/// Every open composer, for the two things that span windows: the main window's undo
/// banner bringing a hidden composer back, and quit asking about unsent messages. (One
/// window per request needs nothing here: `WindowGroup(for:)` already focuses the window
/// presenting a value instead of opening a second.)
///
/// Process-wide because composer windows are separate scenes with no common ancestor
/// but the app, and the banner lives in another window entirely.
@MainActor
final class ComposerWindows {
    static let shared = ComposerWindows()

    private var models: [ObjectIdentifier: ComposerModel] = [:]
    private var pending: PendingSendsModel?
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "composer")

    func register(_ model: ComposerModel) {
        models[ObjectIdentifier(model)] = model
    }

    func unregister(_ model: ComposerModel) {
        models[ObjectIdentifier(model)] = nil
    }

    /// The banner's single model, built on first use, shared so a second main window does
    /// not double the observations.
    func pendingSends(store: MailStore) -> PendingSendsModel {
        if let pending { return pending }
        let model = PendingSendsModel(store: store)
        model.start()
        pending = model
        return model
    }

    /// The composer already editing `draftId`, if any.
    func model(editing draftId: Int64) -> ComposerModel? {
        models.values.first { $0.draftId == draftId }
    }

    /// Shows the composer of a draft whose send was undone or failed.
    ///
    /// - Returns: false when no composer window holds that draft.
    @discardableResult
    func reveal(draftId: Int64) -> Bool {
        guard let model = model(editing: draftId) else { return false }
        model.reveal()
        return true
    }

    // MARK: - Quit

    /// Composers with something the user would lose track of: content typed and not yet
    /// handed to the drafts engine's close.
    var unsaved: [ComposerModel] {
        models.values.filter { $0.hasUnsavedChanges }
    }

    /// ⌘Q. With unsent composers open, asks first (§6.3's beforeunload prompt): save them to
    /// Drafts, discard them, or keep editing.
    func requestQuit() {
        let unsaved = unsaved
        guard !unsaved.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText =
            unsaved.count == 1
            ? String(localized: "You have an unsent message.")
            : String(localized: "You have \(unsaved.count) unsent messages.")
        alert.informativeText = String(
            localized: "Save them to Drafts to finish later, or discard them. Discarded messages cannot be recovered.")
        alert.addButton(withTitle: String(localized: "Save to Drafts"))
        alert.addButton(withTitle: String(localized: "Keep Editing"))
        alert.addButton(withTitle: String(localized: "Discard"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                for model in unsaved { await model.closeForQuit(discard: false) }
                NSApp.terminate(nil)
            }
        case .alertThirdButtonReturn:
            Task {
                for model in unsaved { await model.closeForQuit(discard: true) }
                NSApp.terminate(nil)
            }
        default:
            unsaved.first?.reveal()
        }
    }
}
