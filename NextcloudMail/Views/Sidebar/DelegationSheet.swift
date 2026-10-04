// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// "Delegate account": who may send, receive and delete mail on this account's behalf.
///
/// The list is the mirror's `delegation` rows; Delegate access and Revoke are online-only
/// commands ([ADR-0068](../../../docs/decisions/0068-settings-commands.md)) that write the
/// server's resulting list back, so the sheet only awaits an outcome. There is no user
/// search: nothing in the engines can look up Nextcloud users yet, so a delegate is named by
/// user ID (WS-28 report).
struct DelegationSheet: View {
    let account: AccountRecord
    let model: SidebarStore

    @State private var delegates: [DelegationRecord] = []
    @State private var userId = ""
    @State private var isWorking = false
    @State private var revoking: DelegationRecord?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Delegation").font(.headline)
            Text("Allow users to send, receive, and delete mail on your behalf")
                .foregroundStyle(.secondary)
            List {
                ForEach(delegates, id: \.userId) { delegate in
                    HStack {
                        Text(verbatim: delegate.displayName ?? delegate.userId)
                        Spacer()
                        Button("Revoke access") { revoking = delegate }
                            .buttonStyle(.tertiary)
                            .disabled(isWorking)
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                TextField("User ID", text: $userId)
                Button("Delegate access") { delegate() }
                    .disabled(userId.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                if isWorking { ProgressView().controlSize(.small) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.standard)
        .frame(minWidth: 380)
        .task {
            do {
                for try await rows in model.observeDelegations(accountId: account.id) { delegates = rows }
            } catch {
                delegates = []
            }
        }
        .alert(
            "Revoke access?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { delegate in
            Button("Revoke access", role: .destructive) { revoke(delegate) }
            Button("Cancel", role: .cancel) {}
        } message: { delegate in
            Text("\(delegate.displayName ?? delegate.userId) will no longer be able to act on your behalf")
        }
    }

    private func delegate() {
        let id = userId.trimmingCharacters(in: .whitespaces)
        isWorking = true
        Task {
            if await model.delegate(accountId: account.id, userId: id) { userId = "" }
            isWorking = false
        }
    }

    private func revoke(_ delegate: DelegationRecord) {
        isWorking = true
        Task {
            _ = await model.revokeDelegation(accountId: account.id, userId: delegate.userId)
            isWorking = false
        }
    }
}
