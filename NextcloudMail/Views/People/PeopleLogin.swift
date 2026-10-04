// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// The login a person-related view works in: contacts, autocomplete and the contact queue are
/// per login (ADR-0069), while the views that host them know an account or a session id.
nonisolated struct PeopleLogin: Sendable, Equatable {
    var loginId: Int64
    /// `AccountSession.id` of the login, which is what `AccountEngine` keys its engines by.
    var sessionId: String
    var accountIds: [Int64]

    /// The login of one mail account; nil when either is not in the mirror. A nil
    /// `accountId` picks the first login, for a person shown outside any account.
    static func resolve(store: MailStore, accountId: Int64?) async -> PeopleLogin? {
        do {
            let identity: ServerIdentity
            if let accountId {
                guard let account = try await store.account(id: accountId) else { return nil }
                identity = ServerIdentity(serverURL: account.serverURL, loginName: account.loginName)
            } else {
                guard let first = try await store.logins().min(by: { ($0.id ?? 0) < ($1.id ?? 0) }) else { return nil }
                identity = first.identity
            }
            return try await resolve(store: store, identity: identity)
        } catch {
            return nil
        }
    }

    /// The login an `AccountSession.id` names.
    static func resolve(store: MailStore, sessionId: String) async -> PeopleLogin? {
        do {
            for login in try await store.logins()
            where AccountSession.identifier(server: login.serverURL, loginName: login.loginName) == sessionId {
                return try await resolve(store: store, identity: login.identity)
            }
        } catch {}
        return nil
    }

    private static func resolve(store: MailStore, identity: ServerIdentity) async throws -> PeopleLogin? {
        guard let loginId = try await store.login(for: identity)?.id else { return nil }
        let accounts = try await store.accounts(identity: identity)
        return PeopleLogin(
            loginId: loginId,
            sessionId: AccountSession.identifier(server: identity.serverURL, loginName: identity.loginName),
            accountIds: accounts.map(\.id).sorted()
        )
    }
}
