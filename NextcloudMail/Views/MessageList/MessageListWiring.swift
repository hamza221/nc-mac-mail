// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore

/// The list's two links to the engines, built here so the shell only has to install them.
@MainActor
enum MessageListWiring {
    /// A list model with the follow-up check wired to each row's login.
    static func makeStore(session: AppSession) -> MessageListStore {
        let model = MessageListStore(store: session.store)
        model.followUpCheck = followUpCheck(session: session)
        return model
    }

    /// The preferences, written through each account's queue.
    static func makePreferences(session: AppSession) -> MessageListPreferenceStore {
        let engine = session.engine
        return MessageListPreferenceStore(store: session.store, queue: { engine.mutationQueue(accountId: $0) })
    }

    /// Follow up spans every account, and each login's mirror can only ask its own server,
    /// so the rows are split by login before asking.
    private static func followUpCheck(session: AppSession) -> @MainActor ([MessageRow]) -> Void {
        { [weak session] rows in
            guard let session else { return }
            let byAccount = Dictionary(grouping: rows, by: \.accountId).mapValues { $0.map(\.id) }
            Task {
                for (accountId, ids) in byAccount {
                    guard
                        let account = try? await session.store.account(id: accountId),
                        let login = session.accounts.first(where: { $0.identity == account.identity }),
                        let mirror = session.engine.serverState(sessionId: login.id)
                    else { continue }
                    await mirror.checkFollowUps(messageIds: ids)
                }
            }
        }
    }
}
