// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailSync
import NextcloudUI
import SwiftUI

/// The Files browser sheet: breadcrumbs, a type filter, single or multiple selection, and a
/// "Choose a folder" mode. Present it with `.sheet { FilesPicker(...) }`; it dismisses
/// itself. See ux-spec §Files picker and Files actions (WS-33).
///
/// It reads `filesListing` rows through ``FilesPickerModel`` and asks the login's
/// `FilesListingSync` for fresher ones; nothing here fetches (ADR-0067).
struct FilesPicker: View {
    enum Mode: Hashable {
        case files(filter: FilesTypeFilter = .all, multiple: Bool = true)
        case folder
    }

    let accountId: Int64
    let mode: Mode
    let onChoose: @MainActor (FilesPickerChoice) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var model: FilesPickerModel?
    @State private var unavailable = false
    @State private var filter: FilesTypeFilter = .all
    @State private var selection = Set<String>()

    init(accountId: Int64, mode: Mode, onChoose: @escaping @MainActor (FilesPickerChoice) -> Void) {
        self.accountId = accountId
        self.mode = mode
        self.onChoose = onChoose
        if case .files(let filter, _) = mode {
            _filter = State(initialValue: filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(theme.metrics.spacing.standard)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note = model?.offlineNote(isOffline: session.status.isOffline) {
                NCNoteCard(.warning) { Text(verbatim: note) }
                    .padding(.horizontal, theme.metrics.spacing.standard)
                    .padding(.top, theme.metrics.spacing.tight)
            }
            Divider()
            footer
                .padding(theme.metrics.spacing.standard)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 520)
        .task { await start() }
        .onDisappear { model?.stop() }
        .onChange(of: selection) { old, new in
            // Single selection: keep only the row just clicked.
            if !allowsMultiple, new.count > 1 { selection = Set(new.subtracting(old).prefix(1)) }
        }
        .onChange(of: session.status.isOffline) { _, isOffline in
            if !isOffline { model?.request(force: false) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            Button {
                if let model { navigate(to: FilesPath.parent(of: model.path)) }
            } label: {
                MailSymbol.filesBack.view()
            }
            .buttonStyle(NCButtonStyle.icon)
            .disabled(model?.path == FilesPath.root || model == nil)

            NCBreadcrumbs(
                (model?.breadcrumbs ?? [(FilesPath.root, "Home")]).map {
                    NCBreadcrumbSegment(id: $0.path, title: $0.title)
                }
            ) { segment in
                navigate(to: segment.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .files = mode {
                Picker("Show", selection: $filter) {
                    ForEach(FilesTypeFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Button {
                model?.request(force: true)
            } label: {
                MailSymbol.reload.view()
            }
            .buttonStyle(NCButtonStyle.icon)
            .disabled(session.status.isOffline || model == nil)
            .help("Reload")
        }
    }

    // MARK: - Listing

    @ViewBuilder
    private var content: some View {
        if unavailable {
            Text("Files is not available for this account right now.")
                .foregroundStyle(.secondary)
        } else if let model {
            switch model.content {
            case .pending:
                if session.status.isOffline {
                    Color.clear
                } else {
                    ProgressView("Loading…")
                }
            case .failed:
                VStack(spacing: theme.metrics.spacing.standard) {
                    Text("Could not load this folder")
                        .font(.headline)
                    Button("Try Again") { model.request(force: true) }
                        .buttonStyle(NCButtonStyle.secondary)
                        .disabled(session.status.isOffline)
                }
            case .entries(let entries):
                listing(entries.filter(filter.matches))
            }
        } else {
            ProgressView()
        }
    }

    private func listing(_ entries: [FilesEntry]) -> some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                row(entry)
                    .tag(entry.path)
                    .selectionDisabled(!isSelectable(entry))
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { paths in
            guard paths.count == 1, let path = paths.first, let entry = entries.first(where: { $0.path == path })
            else { return }
            open(entry)
        }
        .overlay {
            if entries.isEmpty {
                Text(filter == .all ? "This folder is empty" : "Nothing of this type here")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: FilesEntry) -> some View {
        NCListItem(entry.name, subtitle: subtitle(entry)) {
            icon(for: entry)
        }
        .opacity(isSelectable(entry) || entry.isFolder ? 1 : 0.5)
    }

    private func icon(for entry: FilesEntry) -> some View {
        let symbol: MailSymbol =
            entry.isFolder ? .folder : (entry.mime?.hasPrefix("image/") == true ? .imageFile : .file)
        return symbol.view()
    }

    private func subtitle(_ entry: FilesEntry) -> String? {
        var parts: [String] = []
        if !entry.isFolder, let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modified = entry.modifiedAt {
            parts.append(
                Date(timeIntervalSince1970: TimeInterval(modified)).formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(NCButtonStyle.secondary)
            Button(chooseTitle) { choose() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(NCButtonStyle.primary)
                .disabled(!canChoose)
        }
    }

    private var chosenEntries: [FilesEntry] {
        guard let model, case .entries(let entries) = model.content else { return [] }
        return entries.filter { selection.contains($0.path) && isSelectable($0) }
    }

    /// In folder mode: the selected subfolder, else the folder being shown.
    private var chosenFolder: String? {
        guard let model else { return nil }
        if let folder = chosenEntries.first(where: \.isFolder) { return folder.path }
        return model.path
    }

    private var chooseTitle: String {
        switch mode {
        case .folder:
            let path = chosenFolder ?? FilesPath.root
            return "Choose \(FilesPath.components(path).last ?? "Home")"
        case .files:
            let count = chosenEntries.count
            return count > 1 ? "Choose (\(count))" : "Choose"
        }
    }

    private var canChoose: Bool {
        switch mode {
        case .folder: model != nil
        case .files: !chosenEntries.isEmpty
        }
    }

    // MARK: - Behaviour

    private var allowsMultiple: Bool {
        if case .files(_, let multiple) = mode { return multiple }
        return false
    }

    private func isSelectable(_ entry: FilesEntry) -> Bool {
        switch mode {
        case .folder: entry.isFolder
        case .files: !entry.isFolder && filter.matches(entry)
        }
    }

    private func start() async {
        guard model == nil else { return }
        guard let context = await FilesContext.resolve(accountId: accountId, session: session) else {
            unavailable = true
            return
        }
        let model = FilesPickerModel(store: session.store, loginId: context.loginId, sync: context.sync)
        self.model = model
        model.open(FilesPath.root)
    }

    private func navigate(to path: String) {
        guard let model, FilesPath.normalize(path) != model.path else { return }
        selection.removeAll()
        model.open(path)
    }

    private func open(_ entry: FilesEntry) {
        if entry.isFolder {
            navigate(to: entry.path)
        } else if isSelectable(entry), case .files = mode {
            selection = [entry.path]
            choose()
        }
    }

    private func choose() {
        switch mode {
        case .folder:
            guard let folder = chosenFolder else { return }
            onChoose(.folder(path: folder))
        case .files(_, let multiple):
            let entries = chosenEntries
            guard !entries.isEmpty else { return }
            onChoose(.files(multiple ? entries : Array(entries.prefix(1))))
        }
        dismiss()
    }
}
