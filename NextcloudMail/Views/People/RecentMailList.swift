// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NextcloudUI
import OSLog
import Observation
import SwiftUI

/// One message in "recent mail with a contact".
nonisolated struct RecentMailItem: Identifiable, Hashable, Sendable {
    var messageId: Int64
    var mailboxId: Int64
    var accountId: Int64
    var subject: String?
    var sentAt: Int64
    var fromEmail: String?
    var fromLabel: String?
    var isSeen: Bool

    var id: Int64 { messageId }

    /// Newest first, one item per message: the same message mirrored into two mailboxes (a
    /// copy in Sent and in a label folder) is listed once, at its newest copy.
    static func collapse(_ rows: [RecentMailRow], limit: Int) -> [RecentMailItem] {
        var seen = Set<String>()
        var items: [RecentMailItem] = []
        for row in rows {
            let identity = row.messageId.map { "m:" + $0 } ?? "id:\(row.id)"
            guard seen.insert(identity).inserted else { continue }
            items.append(
                RecentMailItem(
                    messageId: row.id, mailboxId: row.mailboxId, accountId: row.accountId, subject: row.subject,
                    sentAt: row.sentAt, fromEmail: row.fromEmail, fromLabel: row.fromLabel, isSeen: row.isSeen))
            if items.count == limit { break }
        }
        return items
    }
}

@MainActor
@Observable
final class RecentMailModel {
    let email: String
    let sessionId: String
    let limit: Int
    private(set) var items: [RecentMailItem] = []
    private(set) var hasLoaded = false

    private let store: MailStore
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "people")

    init(email: String, sessionId: String, limit: Int, store: MailStore) {
        self.email = email
        self.sessionId = sessionId
        self.limit = limit
        self.store = store
    }

    /// Follows the mirror until cancelled: new mail with the person appears at the top.
    func run() async {
        guard let login = await PeopleLogin.resolve(store: store, sessionId: sessionId) else {
            hasLoaded = true
            return
        }
        // Copies are collapsed after the fetch, so ask for enough rows to survive a few.
        let rowLimit = limit * 3
        do {
            for try await rows in store.observeRecentMail(
                withAddress: email, accountIds: login.accountIds, limit: rowLimit)
            {
                items = RecentMailItem.collapse(rows, limit: limit)
                hasLoaded = true
            }
        } catch {
            Self.logger.error("recent mail observation stopped: \(String(describing: error), privacy: .public)")
        }
    }
}

/// "Recent mail with this person" for the contact detail pane: the newest mirrored messages of
/// the login with the address in any header.
struct RecentMailList: View {
    let email: String
    let sessionId: String
    let limit: Int
    let onOpen: ((RecentMailItem) -> Void)?

    @Environment(AppSession.self) private var session

    init(email: String, sessionId: String, limit: Int = 20, onOpen: ((RecentMailItem) -> Void)? = nil) {
        self.email = email
        self.sessionId = sessionId
        self.limit = limit
        self.onOpen = onOpen
    }

    var body: some View {
        RecentMailListContent(
            model: RecentMailModel(email: email, sessionId: sessionId, limit: limit, store: session.store),
            onOpen: onOpen ?? { [navigation = session.navigation] item in
                navigation.select(.mailbox(item.mailboxId))
            }
        )
        .id("\(sessionId)|\(email.lowercased())")
    }
}

private struct RecentMailListContent: View {
    @State private var model: RecentMailModel
    let onOpen: (RecentMailItem) -> Void

    @Environment(\.ncTheme) private var theme

    init(model: RecentMailModel, onOpen: @escaping (RecentMailItem) -> Void) {
        _model = State(initialValue: model)
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
            if model.hasLoaded && model.items.isEmpty {
                Text("No mail with this address yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.items) { item in
                Button {
                    onOpen(item)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
            }
        }
        .task { await model.run() }
    }

    private func row(_ item: RecentMailItem) -> some View {
        NCListItem(
            item.subject.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "No subject"),
            subtitle: other(item)
        ) {
            EmptyView()
        } details: {
            NCListItemDetails(date: Date(timeIntervalSince1970: TimeInterval(item.sentAt)), unreadCount: 0)
        }
        .fontWeight(item.isSeen ? nil : .semibold)
    }

    /// Who the message is from — which, when it was sent to this person, is the user.
    private func other(_ item: RecentMailItem) -> String {
        if let label = item.fromLabel, !label.isEmpty { return label }
        return item.fromEmail ?? ""
    }
}
