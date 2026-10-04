// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// The WS-37 sections of a contact card: where the person sits in the organisation chart, and
/// for a system-address-book user the items shared between them and the login
/// ([ux-spec.md](../../../../docs/product/ux-spec.md#teams-shared-items-and-the-organisation-chart-ws-37)).
/// Each section draws nothing when it has nothing to say.
struct ContactTeamsExtras: View {
    let record: ContactRecord
    let book: AddressBookRecord?
    let login: ContactsLoginModel

    @Environment(AppSession.self) private var session

    var body: some View {
        ContactOrgSection(record: record, login: login)
        if let userId = SharedItemsScope.userId(of: record, book: book, loginName: loginName) {
            ContactSharedItemsSection(userId: userId, sessionId: login.sessionId)
        }
    }

    private var loginName: String {
        session.accounts.first { $0.id == login.sessionId }?.loginName ?? ""
    }
}

/// "Organization": the managers above the card and its direct reports, from `X-MANAGERSNAME`
/// over the card's address book, and the whole chart in a sheet.
private struct ContactOrgSection: View {
    let record: ContactRecord
    let login: ContactsLoginModel

    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.ncTheme) private var theme
    @State private var chart: OrgChart?
    @State private var isShowingChart = false

    var body: some View {
        let entries = login.entries.filter { $0.record.addressBookId == record.addressBookId }
        // A ZStack with an explicit empty branch, not a bare Group: a Group applies its
        // modifiers to its children, and with no children the `.task` below never runs
        // (the same trap ContactDetailContent hit), so the chart would never build.
        ZStack {
            if let chart, let id = record.id, chart.people[id] != nil {
                section(chart, id: id)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: Self.version(entries)) {
            chart = await Task.detached(priority: .userInitiated) {
                OrgChart(entries.compactMap(OrgPerson.init(entry:)))
            }.value
        }
    }

    private func section(_ chart: OrgChart, id: Int64) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            Text("Organization").font(.headline)
            let managers = chart.chain(of: id)
            if !managers.isEmpty {
                LabeledContent(String(localized: "Reports to")) {
                    personLinks(managers)
                }
            } else if chart.isManagerMissing(id), let name = chart.people[id]?.managerName {
                Text("Manager \(name) is not in this address book.").font(.callout).foregroundStyle(.secondary)
            }
            if chart.isCycleBroken(id) {
                Text("The managers of this contact form a loop; the chart starts the loop here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            let reports = chart.directReports(of: id)
            if !reports.isEmpty {
                LabeledContent(String(localized: "Direct reports")) {
                    personLinks(reports)
                }
            }
            Button {
                isShowingChart = true
            } label: {
                Label {
                    Text("Show organization chart")
                } icon: {
                    MailSymbol.orgChart.view(size: .small, label: .decorative)
                }
            }
            .buttonStyle(.secondary)
        }
        .sheet(isPresented: $isShowingChart) {
            OrgChartSheet(rows: chart.rows(containing: id), highlighted: id) { personId in
                isShowingChart = false
                browser.reveal(personId)
            }
        }
    }

    private func personLinks(_ people: [OrgPerson]) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            ForEach(people) { person in
                Button(person.name) { browser.reveal(person.id) }
                    .buttonStyle(.link)
                    .help(person.subtitle ?? person.name)
            }
        }
    }

    /// Changes whenever a card of the book changes, so the chart is rebuilt then and only then.
    private static func version(_ entries: [ContactEntry]) -> Int {
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry.id)
            hasher.combine(entry.record.etag)
            hasher.combine(entry.record.vcard.utf8.count)
        }
        return hasher.finalize()
    }
}

/// The chart a card sits in, one indented level per reporting step.
struct OrgChartSheet: View {
    let rows: [OrgChart.Row]
    let highlighted: Int64
    let reveal: (Int64) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Organization chart").font(.headline)
            List(rows) { row in
                Button {
                    reveal(row.person.id)
                } label: {
                    NCListItem(row.person.name, subtitle: row.person.subtitle) {
                        NCAvatar(displayName: row.person.name, size: .small)
                    }
                    .fontWeight(row.person.id == highlighted ? .semibold : .regular)
                }
                .buttonStyle(.plain)
                .padding(.leading, theme.metrics.spacing.loose * CGFloat(row.depth))
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(minWidth: 420)
    }
}

/// "Shared items": the files shared between the login and this user, both directions,
/// newest first, from the `sharedItems` row.
private struct ContactSharedItemsSection: View {
    let userId: String
    let sessionId: String

    @Environment(AppSession.self) private var session
    @Environment(\.ncTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var items: [SharedItem]?
    @State private var hasAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            Text("Shared items").font(.headline)
            if let items {
                if items.isEmpty {
                    Text("No shared items with this contact").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in row(item) }
                }
            } else if hasAnswer {
                Text("Shared items could not be loaded.").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: userId) { await observe() }
    }

    private func row(_ item: SharedItem) -> some View {
        Button {
            if let server, let url = item.webURL(server: server) { openURL(url) }
        } label: {
            NCListItem(
                item.name,
                subtitle: item.isIncoming
                    ? String(localized: "Shared with you · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                    : String(localized: "You shared · \(item.date.formatted(date: .abbreviated, time: .omitted))")
            ) {
                (item.isFolder ? MailSymbol.folder : MailSymbol.file).view(size: .small, label: .decorative)
            }
        }
        .buttonStyle(.plain)
        .help(item.path)
        .disabled(item.fileId == nil || server == nil)
    }

    private var server: URL? {
        session.accounts.first { $0.id == sessionId }?.server
    }

    private func observe() async {
        guard let login = await PeopleLogin.resolve(store: session.store, sessionId: sessionId) else { return }
        await session.engine.serverResults(sessionId: sessionId)?.request(kind: .sharedItems, key: userId)
        do {
            for try await row in session.store.observeServerResult(
                kind: ServerResultKind.sharedItems.rawValue, key: userId, loginId: login.loginId)
            {
                guard let row else { continue }
                hasAnswer = true
                items = SharedItem.items(row)
            }
        } catch {
            TeamsModel.logger.error(
                "shared items observation ended: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
