// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI
import UniformTypeIdentifiers

/// Import a `.vcf` (vCard 3.0 or 4.0, one card or many) into a chosen address book: one queued
/// `contactPut` per card, with progress. Queued means local at once and sent when online, so
/// an import offline is the same import (ADR-0096).
struct VCardImportSheet: View {
    let sessionId: String

    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    @State private var choosingFile = false
    @State private var fileName: String?
    @State private var data: Data?
    @State private var bookURL: String?
    @State private var plan: VCardImportPlan?
    @State private var done = 0
    @State private var phase = Phase.choosing
    @State private var status: String?
    @State private var work: Task<Void, Never>?

    enum Phase: Equatable {
        case choosing
        case importing
        case finished(Int)
    }

    var body: some View {
        let model = browser.login(sessionId)
        let books = Self.targets(model.books)
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Import vCard").font(.headline)
            HStack {
                Text(fileName ?? String(localized: "No file chosen")).foregroundStyle(
                    fileName == nil ? .secondary : .primary)
                Spacer()
                Button("Choose File…") { choosingFile = true }
                    .disabled(phase == .importing)
            }
            Picker("Import into", selection: $bookURL) {
                ForEach(books, id: \.url) { book in
                    Text(book.displayName ?? String(localized: "Address book")).tag(Optional(book.url))
                }
            }
            .disabled(phase == .importing)
            if let plan {
                Text(summary(plan)).font(.callout)
            }
            switch phase {
            case .choosing:
                EmptyView()
            case .importing:
                ProgressView(value: Double(done), total: Double(max(plan?.items.count ?? 1, 1))) {
                    Text("Queued \(done) of \(plan?.items.count ?? 0)")
                }
            case .finished(let count):
                Text("\(count) contacts imported. They reach the server as soon as this Mac is online.")
                    .font(.callout)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if case .finished = phase {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        work?.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Import") { start(books: books) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(plan == nil || phase == .importing)
                }
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 460)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.vCard]) { result in
            switch result {
            case .success(let url): read(url)
            case .failure: status = String(localized: "The file could not be opened.")
            }
        }
        .onAppear {
            if bookURL == nil {
                bookURL = (ContactsActions.defaultBook(for: .all, books: model.books) ?? books.first)?.url
            }
            if fileName == nil { choosingFile = true }
        }
        .task(id: "\(bookURL ?? "")|\(data?.count ?? 0)") { await rebuildPlan(books: books) }
    }

    /// Writable books, Recently contacted aside (the server fills that one itself). Disabled
    /// books are offered: importing into a hidden book is a reasonable thing to want.
    static func targets(_ books: [AddressBookRecord]) -> [AddressBookRecord] {
        books.filter { !$0.isReadOnly && !ContactsListing.isRecentlyContacted($0) }
    }

    private func summary(_ plan: VCardImportPlan) -> String {
        if plan.updateCount == 0 {
            return String(localized: "\(plan.items.count) contacts in the file.")
        }
        return String(
            localized:
                "\(plan.items.count) contacts in the file: \(plan.newCount) new, \(plan.updateCount) already in this address book (they are updated)."
        )
    }

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            data = try Data(contentsOf: url)
            fileName = url.lastPathComponent
            status = nil
            phase = .choosing
        } catch {
            status = String(localized: "The file could not be opened.")
        }
    }

    private func rebuildPlan(books: [AddressBookRecord]) async {
        guard let data, let book = books.first(where: { $0.url == bookURL }), let id = book.id else {
            plan = nil
            return
        }
        do {
            let existing = try await browser.store.contacts(addressBookId: id)
            let bookURL = book.url
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws(VCardImportPlan.Failure) in
                    try VCardImportPlan.make(data: data, bookURL: bookURL, existing: existing)
                }
            }.value
            switch result {
            case .success(let made):
                plan = made
                status = nil
            case .failure(.noCards):
                plan = nil
                status = String(localized: "There are no contacts in this file.")
            case .failure:
                plan = nil
                status = String(localized: "This file is not a vCard file this app can read.")
            }
        } catch {
            plan = nil
            status = String(localized: "The address book could not be read.")
        }
    }

    private func start(books: [AddressBookRecord]) {
        guard let plan, let book = books.first(where: { $0.url == bookURL }) else { return }
        guard let actions = browser.actions(sessionId: sessionId) else {
            status = AddressBookActions.message(for: AddressBookActions.Failure.noQueue)
            return
        }
        phase = .importing
        done = 0
        work = Task {
            let started = ContinuousClock.now
            do {
                try await AddressBookActions(actions).importCards(plan, into: book) { done = $0 }
                ContactsBrowser.logger.info(
                    "vCard import: \(plan.items.count, privacy: .public) cards queued in \(ContinuousClock.now - started, privacy: .public)"
                )
                phase = .finished(plan.items.count)
            } catch is CancellationError {
                phase = .finished(done)
            } catch {
                phase = done > 0 ? .finished(done) : .choosing
                status = AddressBookActions.message(for: error)
            }
        }
    }
}
