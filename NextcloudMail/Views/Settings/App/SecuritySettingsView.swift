// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI
import UniformTypeIdentifiers

/// The Security tab: external-address highlighting, the internal addresses it measures
/// against, and the S/MIME certificate manager. Mailvelope is excluded (ADR-0064).
struct SecuritySettingsView: View {
    @Environment(AppSettingsModel.self) private var model

    @State private var addingInternalAddress = false
    @State private var managingCertificates = false

    var body: some View {
        Form {
            SettingsErrorCard(model: model)
            Section {
                PreferenceToggle(
                    title: String(localized: "Highlight external addresses"),
                    key: AppPreferences.internalAddressesKey,
                    isOn: model.preferences.highlightExternal)
            } footer: {
                Text("Addresses outside the domains and people listed below are highlighted when you write.")
            }

            Section {
                SettingsLoginPicker(model: model)
                ForEach(model.internalAddresses, id: \.address) { record in
                    HStack {
                        (record.type == "domain" ? MailSymbol.domain : MailSymbol.account).view(size: .small)
                        Text(record.address)
                        Spacer()
                        SettingsIconButton(
                            symbol: .remove, label: String(format: String(localized: "Remove %@"), record.address)
                        ) { Task { await model.removeInternalAddress(record) } }
                    }
                }
                Button(String(localized: "Add internal address")) { addingInternalAddress = true }
            } header: {
                Text("Internal addresses")
            }

            Section {
                LabeledContent(String(localized: "S/MIME certificates")) {
                    Button(String(localized: "Manage certificates…")) { managingCertificates = true }
                }
            } header: {
                Text("S/MIME")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingInternalAddress) {
            InternalAddressSheet().environment(model)
        }
        .sheet(isPresented: $managingCertificates) {
            SmimeCertificatesSheet().environment(model)
        }
    }
}

/// One field: `@example.com` is a domain, `a@b` one address (``InternalAddressInput``).
private struct InternalAddressSheet: View {
    @Environment(AppSettingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Add internal address").font(.headline)
            Text("Add a domain like @example.com, or a single address.")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Address or domain"), text: $text)
                .onSubmit { Task { await add() } }
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add")) { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(InternalAddressInput.parse(text) == nil)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 380)
    }

    private func add() async {
        if await model.addInternalAddress(text) { dismiss() }
    }
}

/// §7.2: the table of imported certificates, and the import step.
private struct SmimeCertificatesSheet: View {
    @Environment(AppSettingsModel.self) private var model
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    @State private var importing = false
    @State private var status: SettingsStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("S/MIME certificates").font(.headline)
            SettingsLoginPicker(model: model)
            if importing {
                SmimeImportForm(status: $status) { importing = false }
            } else {
                certificateTable
                SettingsStatusLine(status: status)
                HStack {
                    Button(String(localized: "Import certificate")) {
                        status = nil
                        importing = true
                    }
                    Spacer()
                    Button(String(localized: "Close")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 620, height: 420)
        // A fresh pass so a certificate imported from the web shows (ux-spec).
        .task { session.settingsOpened() }
    }

    @ViewBuilder
    private var certificateTable: some View {
        if model.certificates.isEmpty {
            Text("No certificate imported yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.certificates) {
                TableColumn(String(localized: "Certificate name"), value: \.name)
                TableColumn(String(localized: "E-mail address"), value: \.emailAddress)
                TableColumn(String(localized: "Valid until")) { row in
                    Text(row.validUntil.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                }
                TableColumn("") { row in
                    SettingsIconButton(
                        symbol: .trash, label: String(format: String(localized: "Delete %@"), row.name)
                    ) {
                        Task {
                            if let message = await model.deleteCertificate(row) { status = .failure(message) }
                        }
                    }
                }
                .width(28)
            }
        }
    }
}

/// "Import certificate": PKCS #12 (converted on this Mac) or PEM files.
private struct SmimeImportForm: View {
    @Binding var status: SettingsStatus?
    let onBack: () -> Void

    @Environment(AppSettingsModel.self) private var model
    @Environment(\.ncTheme) private var theme

    enum Format: Hashable { case pkcs12, pem }
    enum Slot { case pkcs12, certificate, privateKey }

    @State private var format = Format.pkcs12
    @State private var pkcs12: URL?
    @State private var certificate: URL?
    @State private var privateKey: URL?
    @State private var password = ""
    @State private var choosing: Slot?
    @State private var isImporting = false

    var body: some View {
        Form {
            Picker(String(localized: "Format"), selection: $format) {
                Text("PKCS #12 Certificate").tag(Format.pkcs12)
                Text("PEM Certificate").tag(Format.pem)
            }
            .pickerStyle(.segmented)
            switch format {
            case .pkcs12:
                fileRow(String(localized: "PKCS #12 Certificate"), url: pkcs12, slot: .pkcs12)
                SecureField(String(localized: "Password"), text: $password)
            case .pem:
                fileRow(String(localized: "Certificate"), url: certificate, slot: .certificate)
                fileRow(String(localized: "Private key (optional)"), url: privateKey, slot: .privateKey)
                Text(
                    "The private key is only required if you intend to send signed and encrypted emails using this certificate."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("The private key must not be protected by a passphrase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsStatusLine(status: status)
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
            allowedContentTypes: choosing == .pkcs12 ? [.pkcs12] : [.data]
        ) { result in
            guard case .success(let url) = result, let slot = choosing else { return }
            switch slot {
            case .pkcs12: pkcs12 = url
            case .certificate: certificate = url
            case .privateKey: privateKey = url
            }
        }
        HStack {
            Button(String(localized: "Back")) {
                status = nil
                onBack()
            }
            Spacer()
            if isImporting { ProgressView().controlSize(.small) }
            Button(String(localized: "Import")) { Task { await runImport() } }
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting || (format == .pkcs12 ? pkcs12 == nil : certificate == nil))
        }
    }

    private func fileRow(_ title: String, url: URL?, slot: Slot) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url?.lastPathComponent ?? String(localized: "No file chosen"))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Choose…")) { choosing = slot }
            }
        }
    }

    private func runImport() async {
        isImporting = true
        defer { isImporting = false }
        status = nil
        let result: SmimeImportResult
        switch format {
        case .pkcs12:
            guard let data = pkcs12.flatMap(Self.read) else {
                status = .failure(String(localized: "Failed to import the certificate"))
                return
            }
            result = await model.importPKCS12(data, password: password)
            password = ""
        case .pem:
            guard let data = certificate.flatMap(Self.read) else {
                status = .failure(String(localized: "Failed to import the certificate"))
                return
            }
            result = await model.importPEM(certificate: data, privateKey: privateKey.flatMap(Self.read))
        }
        switch result {
        case .imported:
            status = .success(result.message)
            onBack()
        case .failed(let message):
            status = .failure(message)
        }
    }

    /// A file the open panel handed over, read inside its security scope.
    private static func read(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}
