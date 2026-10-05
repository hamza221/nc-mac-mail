// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// Share one address book with a user or group, read-only or not. The sharee search is the
/// `sharees` server result: the sheet asks for it and reads the row the fetcher writes.
struct AddressBookShareSheet: View {
    let sessionId: String
    let book: AddressBookRecord

    @Environment(AppSession.self) private var session
    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    @State private var term = ""
    @State private var readOnly = true
    @State private var sharees: [ShareeSuggestion] = []
    @State private var shared: [String] = []
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Share \(book.displayName ?? String(localized: "address book"))").font(.headline)
            TextField(String(localized: "Search for users or groups"), text: $term)
            Toggle("Read-only", isOn: $readOnly)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
                    ForEach(sharees) { sharee in
                        Button {
                            share(with: sharee)
                        } label: {
                            HStack {
                                (sharee.type == "group" ? MailSymbol.group : MailSymbol.account).view(size: .small)
                                Text(sharee.displayName)
                                Text(sharee.shareWith).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 120)
            if !shared.isEmpty {
                Text("Shared with \(shared.joined(separator: ", ")).").font(.caption)
            }
            Text("Sharing again with someone changes their access to what Read-only says now.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 440)
        .task(id: term) { await search(term) }
    }

    /// Debounced like the web's sharee search; the answer arrives as a `serverResult` row.
    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let loginId = browser.login(sessionId).loginId else {
            sharees = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let fetcher = session.engine.serverResults(sessionId: sessionId)
        await fetcher?.request(kind: .sharees, key: trimmed)
        let loginName = session.accounts.first { $0.id == sessionId }?.loginName ?? ""
        do {
            for try await row in browser.store.observeServerResult(
                kind: ServerResultKind.sharees.rawValue, key: trimmed, loginId: loginId)
            {
                guard !Task.isCancelled else { return }
                var payload: AnyJSON?
                if let row, case .ready(let data)? = try? ServerResultPayload(payloadJSON: row.payloadJSON) {
                    payload = data
                }
                sharees = ShareeSuggestion.suggestions(from: payload, excluding: [], selfUserId: loginName)
            }
        } catch {
            ContactsBrowser.logger.error(
                "sharee observation stopped: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func share(with sharee: ShareeSuggestion) {
        let readOnly = readOnly
        Task {
            guard let actions = browser.actions(sessionId: sessionId) else {
                status = AddressBookActions.message(for: AddressBookActions.Failure.noQueue)
                return
            }
            do {
                try await AddressBookActions(actions).share(book, with: sharee, readOnly: readOnly)
                shared.append(sharee.displayName)
                term = ""
                status = nil
            } catch {
                status = AddressBookActions.message(for: error)
            }
        }
    }
}
