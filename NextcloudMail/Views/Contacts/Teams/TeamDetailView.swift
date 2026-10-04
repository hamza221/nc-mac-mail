// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// What a Contacts content column shows for `ContactsScope.team`: the team itself, in place of
/// the (always empty) contact list. Every other scope passes through to `fallback`.
struct TeamScopeOverlay<Fallback: View>: View {
    let sessionId: String
    let scope: ContactsScope
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if case .team(let teamId) = scope {
            TeamDetailView(sessionId: sessionId, teamId: teamId)
        } else {
            fallback()
        }
    }
}

/// One team: its description, members with their levels, and the actions the login's level
/// allows — add members, change levels, accept requests, remove, settings, leave, delete
/// ([ux-spec.md](../../../../docs/product/ux-spec.md#teams-shared-items-and-the-organisation-chart-ws-37)).
struct TeamDetailView: View {
    let sessionId: String
    let teamId: String

    @Environment(AppSession.self) private var session
    @Environment(\.ncTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isAdding = false
    @State private var isEditing = false
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var failure: String?

    var body: some View {
        let teams = TeamsModels.model(sessionId, session: session)
        Group {
            if !teams.isAvailable {
                // No Circles (or no answer yet): nothing about Teams is drawn.
                Color.clear
            } else if let team = teams.team(teamId) {
                content(team, teams: teams)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Team not found")
                    } icon: {
                        MailSymbol.team.view(size: .large, label: .decorative)
                    }
                } description: {
                    Text("It may have been deleted, or you may have left it.")
                }
            }
        }
        .background(.background)
        .task(id: teamId) { teams.refresh() }
        .alert(
            "Teams", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func content(_ team: TeamSummary, teams: TeamsModel) -> some View {
        List {
            Section {
                header(team, teams: teams)
            }
            Section {
                ForEach(team.members) { member in
                    TeamMemberRow(member: member, team: team, isSelf: team.isSelf(member)) { command in
                        run(command, teams: teams)
                    }
                }
            } header: {
                Text("Members")
            }
        }
        .sheet(isPresented: $isAdding) {
            AddTeamMemberSheet(team: team, teams: teams, loginName: loginName)
        }
        .sheet(isPresented: $isEditing) {
            TeamSettingsSheet(team: team, teams: teams)
        }
        .confirmationDialog(
            String(localized: "Leave \(team.name)?"), isPresented: $confirmLeave, titleVisibility: .visible
        ) {
            Button("Leave team", role: .destructive) { run(.leave(teamId: team.remoteId), teams: teams) }
        }
        .confirmationDialog(
            String(localized: "Delete \(team.name)?"), isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete team", role: .destructive) { run(.delete(teamId: team.remoteId), teams: teams) }
        } message: {
            Text("Everything shared with this team stops being shared with its members.")
        }
        .navigationTitle(team.name)
    }

    private func header(_ team: TeamSummary, teams: TeamsModel) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            if !team.description.isEmpty {
                Text(verbatim: team.description).textSelection(.enabled)
            }
            Text(summaryLine(team)).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: theme.metrics.spacing.tight) {
                if team.canManageMembers {
                    Button("Add members") { isAdding = true }.buttonStyle(.primary)
                }
                if team.canEditSettings {
                    Button("Team settings") { isEditing = true }.buttonStyle(.secondary)
                }
                Menu {
                    if let url = team.url {
                        Button("Open in browser") { openURL(url) }
                    }
                    if team.canLeave {
                        Button {
                            confirmLeave = true
                        } label: {
                            Label {
                                Text("Leave team")
                            } icon: {
                                MailSymbol.leaveTeam.view(size: .small, label: .decorative)
                            }
                        }
                    }
                    if team.canDelete {
                        Divider()
                        Button("Delete team", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    MailSymbol.more.view(size: .small, label: .text("More actions"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, theme.metrics.spacing.tight)
    }

    private func summaryLine(_ team: TeamSummary) -> String {
        let members = String(localized: "\(team.population) members")
        guard let owner = team.ownerName else { return members }
        return team.isOwner
            ? String(localized: "\(members) · You own this team")
            : String(localized: "\(members) · Owned by \(owner)")
    }

    private var loginName: String {
        session.accounts.first { $0.id == sessionId }?.loginName ?? ""
    }

    private func run(_ command: TeamCommand, teams: TeamsModel) {
        Task { failure = await teams.perform(command) }
    }
}

/// One member: name, kind and level, and a menu with what the login may do to them.
private struct TeamMemberRow: View {
    let member: TeamMemberSummary
    let team: TeamSummary
    let isSelf: Bool
    let run: (TeamCommand) -> Void

    var body: some View {
        NCListItem(member.displayName, subtitle: "\(member.kindTitle) · \(member.levelTitle)") {
            NCAvatar(displayName: member.displayName, user: member.kind == .user ? member.userId : nil, size: .small)
        } trailing: {
            if hasActions {
                Menu {
                    actions
                } label: {
                    MailSymbol.more.view(size: .small, label: .text("Member actions"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .contextMenu { actions }
    }

    private var hasActions: Bool {
        team.canAccept(member) || team.canChangeLevel(of: member) || team.canRemove(member)
            || (isSelf && team.canLeave)
    }

    @ViewBuilder
    private var actions: some View {
        if team.canAccept(member) {
            Button("Accept") { run(.acceptMember(teamId: team.remoteId, memberId: member.memberId)) }
            Button("Reject") { run(.removeMember(teamId: team.remoteId, memberId: member.memberId)) }
            Divider()
        }
        if team.canChangeLevel(of: member) {
            ForEach(team.availableLevels(for: member), id: \.self) { level in
                Button(levelLabel(level)) {
                    run(.setLevel(teamId: team.remoteId, memberId: member.memberId, level: level))
                }
            }
            Divider()
        }
        if isSelf && team.canLeave {
            Button("Leave team") { run(.leave(teamId: team.remoteId)) }
        } else if team.canRemove(member) && !member.isRequesting {
            Button("Remove member", role: .destructive) {
                run(.removeMember(teamId: team.remoteId, memberId: member.memberId))
            }
        }
    }

    /// Web Contacts' wording (`levelChangeLabel`).
    private func levelLabel(_ level: TeamMemberLevel) -> String {
        if level == .owner { return String(localized: "Promote as sole owner") }
        return member.levelValue < level.rawValue
            ? String(localized: "Promote to \(level.title)") : String(localized: "Demote to \(level.title)")
    }
}

/// Add members: users and groups (the `sharees` search), an email address, or another of the
/// login's teams — web Contacts' picker groups, minus federated users and contacts, which the
/// server only offers through the same search.
struct AddTeamMemberSheet: View {
    let team: TeamSummary
    let teams: TeamsModel
    let loginName: String

    enum Kind: Hashable { case people, email, team }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var kind = Kind.people
    @State private var term = ""
    @State private var email = ""
    @State private var sharees: [ShareeSuggestion] = []
    @State private var isWorking = false
    @State private var failure: String?
    @State private var added: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Add members to \(team.name)").font(.headline)
            Picker("Add", selection: $kind) {
                Text("Users and groups").tag(Kind.people)
                Text("Email address").tag(Kind.email)
                Text("Team").tag(Kind.team)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch kind {
            case .people: peoplePicker
            case .email: emailField
            case .team: teamPicker
            }
            if !added.isEmpty {
                Text("Added: \(added.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(.callout).foregroundStyle(theme.colors.error.element)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(width: 440)
        .task(id: term) { await search() }
    }

    private var peoplePicker: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            TextField("Search users and groups", text: $term).textFieldStyle(.roundedBorder)
            List(sharees) { sharee in
                Button {
                    add(sharee.shareWith, type: sharee.type == "group" ? .group : .user, label: sharee.displayName)
                } label: {
                    NCListItem(
                        sharee.displayName,
                        subtitle: sharee.type == "group" ? String(localized: "Group") : sharee.shareWith
                    ) {
                        NCAvatar(
                            displayName: sharee.displayName, user: sharee.type == "group" ? nil : sharee.shareWith,
                            size: .small)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isMember(sharee.shareWith, sharee.type == "group" ? .group : .user))
            }
            .frame(minHeight: 160)
        }
    }

    private var emailField: some View {
        HStack {
            TextField("name@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addEmail)
            Button("Add", action: addEmail).disabled(!Self.looksLikeAddress(email) || isWorking)
        }
    }

    private var teamPicker: some View {
        let others = teams.teams.filter { $0.remoteId != team.remoteId }
        return List(others) { other in
            Button {
                add(other.remoteId, type: .team, label: other.name)
            } label: {
                NCListItem(other.name, subtitle: String(localized: "\(other.population) members")) {
                    MailSymbol.team.view(size: .small, label: .decorative)
                }
            }
            .buttonStyle(.plain)
            .disabled(isMember(other.name, .team))
        }
        .frame(minHeight: 160)
        .overlay {
            if others.isEmpty { Text("You are in no other team.").foregroundStyle(.secondary) }
        }
    }

    private func isMember(_ userId: String, _ type: TeamMemberType) -> Bool {
        team.members.contains { $0.kind == type && $0.userId == userId }
    }

    private func addEmail() {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard Self.looksLikeAddress(address) else { return }
        add(address, type: .mail, label: address)
        email = ""
    }

    private func add(_ userId: String, type: TeamMemberType, label: String) {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        Task {
            failure = await teams.perform(.addMember(teamId: team.remoteId, userId: userId, type: type))
            if failure == nil { added.append(label) }
            isWorking = false
        }
    }

    private func search() async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let loginId = teams.loginId else {
            sharees = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        teams.requestSharees(trimmed)
        do {
            for try await row in teams.store.observeServerResult(
                kind: ServerResultKind.sharees.rawValue, key: trimmed, loginId: loginId)
            {
                guard let row, case .ready(let data)? = try? ServerResultPayload(payloadJSON: row.payloadJSON) else {
                    sharees = []
                    continue
                }
                sharees = ShareeSuggestion.suggestions(from: data, excluding: [], selfUserId: loginName)
            }
        } catch {
            TeamsModel.logger.error(
                "sharee observation ended: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Enough to keep an obvious typo off the server; the server validates for real.
    nonisolated static func looksLikeAddress(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".")
    }
}

/// Team settings: name, description and web Contacts' options.
struct TeamSettingsSheet: View {
    let team: TeamSummary
    let teams: TeamsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var name: String
    @State private var description: String
    @State private var config: TeamConfig
    @State private var isWorking = false
    @State private var failure: String?

    init(team: TeamSummary, teams: TeamsModel) {
        self.team = team
        self.teams = teams
        _name = State(initialValue: team.name)
        _description = State(initialValue: team.description)
        _config = State(initialValue: team.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Team settings").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...6)
                ForEach(TeamSummary.optionGroups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.options, id: \.0.rawValue) { option, label in
                            Toggle(label, isOn: binding(option))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let failure {
                Text(failure).font(.callout).foregroundStyle(theme.colors.error.element)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(width: 520)
    }

    private func binding(_ option: TeamConfig) -> Binding<Bool> {
        Binding(
            get: { config.contains(option) },
            set: { isOn in
                if isOn { config.insert(option) } else { config.remove(option) }
            })
    }

    private func save() {
        let commands = TeamSettingsChanges.commands(
            team: team, name: name, description: description, config: config)
        guard !commands.isEmpty else {
            dismiss()
            return
        }
        isWorking = true
        failure = nil
        Task {
            for command in commands {
                if let message = await teams.perform(command) {
                    failure = message
                    isWorking = false
                    return
                }
            }
            isWorking = false
            dismiss()
        }
    }
}

/// The edits a settings save sends: only what changed, name first.
nonisolated enum TeamSettingsChanges {
    static func commands(team: TeamSummary, name: String, description: String, config: TeamConfig) -> [TeamCommand] {
        var commands: [TeamCommand] = []
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != team.name { commands.append(.rename(teamId: team.remoteId, name: name)) }
        if description != team.description {
            commands.append(.setDescription(teamId: team.remoteId, description: description))
        }
        if config != team.config { commands.append(.setConfig(teamId: team.remoteId, config: config.rawValue)) }
        return commands
    }
}
