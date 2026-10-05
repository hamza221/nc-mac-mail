// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import OSLog
import Observation
import SwiftUI

/// Which mailbox the Get info panel is about. Identifiable so `.sheet(item:)` can present on
/// it and dismiss by setting it back to nil.
struct MailboxInfoTarget: Identifiable, Hashable, Sendable {
    let accountId: Int64
    let mailboxId: Int64

    /// A local mailbox id is unique mirror-wide (ADR-0033), so it alone identifies the panel.
    var id: Int64 { mailboxId }
}

/// The panel's two live reads: the mailbox row, and the counts over its messages.
///
/// Both are store observations, so the panel moves while the backfill runs or the user triages
/// and never waits on the server -- Get info describes the mirror, which is already local.
@MainActor
@Observable
final class MailboxInfoModel {
    let target: MailboxInfoTarget
    private(set) var mailbox: MailboxRecord?
    private(set) var counts: MailboxCounts?
    /// True once the row has been read and found missing: the folder was deleted or the
    /// account removed while the panel was open.
    private(set) var isGone = false

    private let store: MailStore

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "sidebar")

    init(target: MailboxInfoTarget, store: MailStore) {
        self.target = target
        self.store = store
    }

    /// Runs until the calling task is cancelled, which `.task` does when the panel closes.
    func observeMailbox() async {
        let mailboxId = target.mailboxId
        do {
            for try await record in store.observeMailbox(id: mailboxId) {
                mailbox = record
                isGone = record == nil
            }
        } catch {
            Self.logger.error(
                "mailbox info observation stopped for mailbox \(mailboxId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    func observeCounts() async {
        let mailboxId = target.mailboxId
        do {
            for try await fresh in store.observeMailboxCounts(mailboxId: mailboxId) {
                counts = fresh
            }
        } catch {
            Self.logger.error(
                "mailbox counts observation stopped for mailbox \(mailboxId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}

/// Get info for one folder: what the server last said about it, what the mirror holds, and
/// whether its last sync failed ([ux-spec.md](../../../docs/product/ux-spec.md#sidebar)).
struct MailboxInfoView: View {
    @State private var model: MailboxInfoModel
    @Environment(\.ncTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    init(model: MailboxInfoModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            content
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: Self.width)
        .task { await model.observeMailbox() }
        .task { await model.observeCounts() }
    }

    @ViewBuilder
    private var content: some View {
        if let mailbox = model.mailbox {
            Text(mailbox.displayName)
                .font(.headline.weight(theme.typography.heading))
            Form {
                serverSection(mailbox)
                mirrorSection(mailbox)
                if mailbox.syncFailureCount > 0 {
                    Section {
                        NCNoteCard(.warning, title: "The last sync of this folder failed") {
                            Text(MailboxInfoText.failureExplanation(mailbox.lastSyncError))
                            Text(MailboxInfoText.failureCount(mailbox.syncFailureCount))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.isGone {
            // `.secondary` rather than a token: `NCColorTokens` has no muted-text colour
            // (docs/feedback/library-feedback.md).
            Text("This folder no longer exists.")
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Loading"))
        }
    }

    private func serverSection(_ mailbox: MailboxRecord) -> some View {
        Section {
            LabeledContent("Messages") {
                Text(mailbox.totalCount.map(SettingsFormatting.messageCount) ?? String(localized: "Unknown"))
            }
            LabeledContent("Unread") {
                Text(SettingsFormatting.messageCount(mailbox.unreadCount))
            }
        } header: {
            Text("On the server")
        } footer: {
            // The row read here is the raw column, the server's own figure, which only a
            // folder refresh updates (ADR-0060). The mirror's figure below moves with every
            // local change, so the two can differ for a moment and that is expected.
            Text("As of the last folder refresh.")
        }
    }

    private func mirrorSection(_ mailbox: MailboxRecord) -> some View {
        Section {
            LabeledContent("Status") {
                Text(MailboxInfoText.mirrorState(mailbox: mailbox, counts: model.counts))
            }
            if mailbox.isMirrored, let counts = model.counts {
                LabeledContent("Messages") {
                    Text(SettingsFormatting.messageCount(counts.messageCount))
                }
                LabeledContent("Unread") {
                    Text(SettingsFormatting.messageCount(counts.unreadCount))
                }
                LabeledContent("Downloaded") {
                    Text(SettingsFormatting.messageCount(counts.bodiesPresent))
                }
                if counts.bodiesFailed > 0 {
                    LabeledContent("Could not download") {
                        Text(SettingsFormatting.messageCount(counts.bodiesFailed))
                    }
                }
            }
            LabeledContent("Last sync") {
                Text(SettingsFormatting.lastSync(mailbox.lastSyncAt))
            }
        } header: {
            Text("On this Mac")
        }
    }

    /// The sheet's shape. Window chrome rather than a spacing or radius token, so it is not a
    /// theme metric -- the same reasoning `MoveDestinationList` applies to its popover.
    private static let width = 360.0
}

/// The panel's sentences, as pure functions of the rows so they can be tested without a view.
enum MailboxInfoText {
    /// One phrase for where this folder's mirror has got to.
    ///
    /// Body completeness is counted from the messages rather than read from
    /// `mailbox.bodiesComplete`: nothing in the mirror sets that column today, so trusting it
    /// would leave every folder "downloading" forever.
    static func mirrorState(mailbox: MailboxRecord, counts: MailboxCounts?) -> String {
        guard mailbox.isMirrored else {
            return String(localized: "Not mirrored. This folder opens from the server without a local copy.")
        }
        guard mailbox.envelopesComplete else {
            return String(localized: "Downloading the message list")
        }
        guard let counts else { return String(localized: "Mirrored") }
        let remaining = counts.messageCount - counts.bodiesPresent - counts.bodiesFailed
        guard remaining > 0 else { return String(localized: "Complete") }
        return String(
            format: String(localized: "Downloading messages, %@ to go"),
            SettingsFormatting.messageCount(remaining)
        )
    }

    /// `lastSyncError` in plain words.
    ///
    /// The column holds `describe(_:)`'s rendering from `NCMailSync`: a `MailError` or
    /// `SyncError` case name, or an error's type name, never anything a user wrote. It is
    /// still matched against known prefixes rather than shown, because a case name is not a
    /// sentence, and anything unrecognised gets the generic one -- the stored text is never
    /// echoed, so a future writer that stores something less careful cannot leak through here.
    static func failureExplanation(_ lastSyncError: String?) -> String {
        let error = lastSyncError ?? ""
        if SessionExpiryTrigger.isAuthenticationLost(error) {
            return String(localized: "The server no longer accepts this account's app password. Sign in again.")
        }
        if error.hasPrefix("forbidden") {
            return String(localized: "The server refused access to this folder.")
        }
        if error.hasPrefix("notFound") {
            return String(localized: "The server could not find this folder. It may have been renamed or deleted.")
        }
        if error.hasPrefix("mailboxNotCached") || error.hasPrefix("syncInProgress")
            || error.hasPrefix("primingDidNotFinish")
        {
            return String(localized: "The server was still preparing this folder and did not finish in time.")
        }
        if error.hasPrefix("rateLimited") {
            return String(localized: "The server asked the app to slow down.")
        }
        if error.hasPrefix("server") {
            return String(localized: "The server answered with an error.")
        }
        if error.hasPrefix("transport") {
            return String(localized: "The server could not be reached.")
        }
        if error.hasPrefix("decoding") {
            return String(localized: "The server's answer could not be read. Its Mail version may be too new.")
        }
        return String(localized: "Something went wrong while syncing this folder.")
    }

    /// The count, and the reassurance that matters: nothing local was lost, and it retries.
    static func failureCount(_ count: Int) -> String {
        let attempts =
            count == 1
            ? String(localized: "It has failed once.")
            : String(format: String(localized: "It has failed %lld times in a row."), count)
        return attempts + " " + String(localized: "Everything on this Mac stays readable; the next sync tries again.")
    }
}
