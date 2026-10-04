// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailSync
import NextcloudUI
import SwiftUI

/// The Teams rows of one login's Contacts section: one per team and "New team…"
/// ([ux-spec.md](../../../../docs/product/ux-spec.md#teams-shared-items-and-the-organisation-chart-ws-37)).
///
/// Draws nothing at all unless the login's `teams` row is `ready` — on a server without the
/// Circles app there is no Teams row, no empty state and no disabled button (ADR-0097).
struct TeamsSidebarRows: View {
    let model: ContactsLoginModel

    @Environment(AppSession.self) private var session
    @State private var isCreating = false

    var body: some View {
        let teams = TeamsModels.model(model.sessionId, session: session)
        if teams.isAvailable {
            ForEach(teams.teams) { team in
                NCNavigationItem(team.name, icon: MailSymbol.team.symbol, count: team.population)
                    .accessibilityElement(children: .combine)
                    .tag(SidebarSelection.contacts(sessionId: model.sessionId, scope: .team(team.remoteId)))
            }
            Button {
                isCreating = true
            } label: {
                NCNavigationItem(String(localized: "New team…"), icon: MailSymbol.add.symbol)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isCreating) {
                NewTeamSheet(teams: teams)
            }
        }
    }
}

/// "New team": a name, then `POST …/circles` (online only; the server names conflicts).
struct NewTeamSheet: View {
    let teams: TeamsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var name = ""
    @State private var isWorking = false
    @State private var failure: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("New team").font(.headline)
            Text("Create your own teams for sharing. Add Nextcloud users, contacts, or anyone via email.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Team name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if let failure {
                Text(failure).font(.callout).foregroundStyle(theme.colors.error.element)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create team", action: create)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isWorking)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(width: 380)
    }

    private func create() {
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        failure = nil
        Task {
            failure = await teams.perform(.create(name: trimmed))
            isWorking = false
            if failure == nil { dismiss() }
        }
    }
}
