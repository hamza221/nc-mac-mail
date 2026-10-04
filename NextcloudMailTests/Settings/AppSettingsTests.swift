// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Security
import Testing

@testable import NextcloudMail

// MARK: - Default mail app (§7 General)

@Suite("Default mail app check")
struct DefaultMailAppCheckTests {
    private let bundle = URL(filePath: "/Applications/Nextcloud Mail.app", directoryHint: .isDirectory)

    @Test func theLabelSaysWhatTheButtonWouldDo() {
        #expect(DefaultMailAppCheck.label(isDefault: true) == "Default mail app")
        #expect(DefaultMailAppCheck.label(isDefault: false) == "Set as default mail app")
    }

    @Test func thisBundleHandlingMailtoIsTheDefault() {
        let check = DefaultMailAppCheck(handler: { bundle }, bundleURL: bundle)
        #expect(check.isDefault())
    }

    @Test func noHandlerOrAnotherAppIsNotTheDefault() {
        #expect(!DefaultMailAppCheck(handler: { nil }, bundleURL: bundle).isDefault())
        let mail = URL(filePath: "/System/Applications/Mail.app", directoryHint: .isDirectory)
        #expect(!DefaultMailAppCheck(handler: { mail }, bundleURL: bundle).isDefault())
    }

    @Test func aSecondCopyElsewhereIsADifferentBundle() {
        let copy = URL(filePath: "/Users/someone/Downloads/Nextcloud Mail.app", directoryHint: .isDirectory)
        #expect(!DefaultMailAppCheck(handler: { copy }, bundleURL: bundle).isDefault())
    }

    @Test func spellingDifferencesDoNotMatter() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ws38-\(UUID().uuidString)")
        let real = directory.appending(path: "Real.app", directoryHint: .isDirectory)
        let link = directory.appending(path: "Link.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // Launch Services' trailing slash, and a symlinked path to the same bundle.
        let check = DefaultMailAppCheck(handler: { URL(string: real.absoluteString + "/") }, bundleURL: link)
        #expect(check.isDefault())
    }
}

// MARK: - PKCS #12 → PEM (§7.2)

/// The fixtures are throwaway identities made with LibreSSL's `openssl pkcs12 -export`
/// (RSA 2048, EC P-256, and a certificate without a key), all with password `nc-mail-test`.
@Suite("S/MIME PKCS #12 conversion")
struct SmimeCertificateConverterTests {
    static let password = "nc-mail-test"

    /// The marker `Bundle(for:)` needs: Swift Testing suites are structs.
    private final class BundleMarker {}

    /// The test bundle's copy of a fixture, never the checkout's: the host app reading the
    /// repository under the developer's home trips the folder-access consent, and a single
    /// denial there is remembered — every run after it fails the read with EPERM. The copy
    /// in the bundle is the test's own, wherever the build put it.
    static func fixture(_ name: String) throws -> Data {
        struct MissingFixture: Error { let name: String }
        guard let url = Bundle(for: BundleMarker.self).url(forResource: name, withExtension: nil)
        else { throw MissingFixture(name: name) }
        return try Data(contentsOf: url)
    }

    /// The base64 bodies of every `label` block in a PEM text.
    static func blocks(_ pem: Data, label: String) -> [Data] {
        let text = String(decoding: pem, as: UTF8.self)
        let parts = text.components(separatedBy: "-----BEGIN \(label)-----\n").dropFirst()
        return parts.compactMap { part in
            guard let body = part.components(separatedBy: "\n-----END \(label)-----").first else { return nil }
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        }
    }

    @Test func anRSAIdentityBecomesACertificateAndAPKCS1Key() throws {
        let pair = try SmimeCertificateConverter.pemPair(
            fromPKCS12: try Self.fixture("smime-rsa.p12"), password: Self.password)
        let certificates = Self.blocks(pair.certificate, label: "CERTIFICATE")
        #expect(certificates.count == 1)
        let der = try #require(certificates.first)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Lorelai Gilmore")

        let keyDER = try #require(Self.blocks(pair.privateKey, label: "RSA PRIVATE KEY").first)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        let key = try #require(SecKeyCreateWithData(keyDER as CFData, attributes as CFDictionary, nil))
        // The key is the certificate's: same public key.
        let fromKey = SecKeyCopyExternalRepresentation(try #require(SecKeyCopyPublicKey(key)), nil) as Data?
        let fromCertificate = SecCertificateCopyKey(certificate).flatMap { SecKeyCopyExternalRepresentation($0, nil) }
        #expect(fromKey == fromCertificate as Data?)
    }

    @Test func anECIdentityBecomesASEC1Key() throws {
        let pair = try SmimeCertificateConverter.pemPair(
            fromPKCS12: try Self.fixture("smime-ec.p12"), password: Self.password)
        let der = [UInt8](try #require(Self.blocks(pair.privateKey, label: "EC PRIVATE KEY").first))
        // SEQUENCE { INTEGER 1, OCTET STRING (32), [0] prime256v1, [1] BIT STRING }.
        #expect(der.starts(with: [0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20]))
        let curve: [UInt8] = [0xA0, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        #expect(Array(der[39..<51]) == curve)
        #expect(Array(der[51..<55]) == [0xA1, 0x44, 0x03, 0x42])
        #expect(der.count == 0x77 + 2)
    }

    @Test func aWrongPasswordIsUnreadableAndSaysSo() throws {
        #expect(throws: SmimeCertificateConverter.ConversionError.unreadable) {
            try SmimeCertificateConverter.pemPair(fromPKCS12: try Self.fixture("smime-rsa.p12"), password: "wrong")
        }
        #expect(throws: SmimeCertificateConverter.ConversionError.unreadable) {
            try SmimeCertificateConverter.pemPair(fromPKCS12: Data("not pkcs12".utf8), password: Self.password)
        }
        #expect(
            SmimeCertificateConverter.ConversionError.unreadable.message
                == "Failed to import the certificate. Please check the password.")
    }

    @Test func aFileWithoutAKeyIsRefused() throws {
        #expect(throws: SmimeCertificateConverter.ConversionError.notExactlyOneIdentity) {
            try SmimeCertificateConverter.pemPair(
                fromPKCS12: try Self.fixture("smime-nokey.p12"), password: Self.password)
        }
    }

    @Test func derLengthsUseTheLongFormFrom128() {
        #expect(SmimeCertificateConverter.derLength(0x7F) == [0x7F])
        #expect(SmimeCertificateConverter.derLength(0x80) == [0x81, 0x80])
        #expect(SmimeCertificateConverter.derLength(0x1234) == [0x82, 0x12, 0x34])
    }

    @Test func pemWrapsAt64Columns() {
        let pem = SmimeCertificateConverter.pem(label: "X", der: Data(repeating: 0xAB, count: 96))
        let lines = pem.split(separator: "\n")
        #expect(lines.first == "-----BEGIN X-----")
        #expect(lines.last == "-----END X-----")
        #expect(lines.dropFirst().dropLast().allSatisfy { $0.count <= 64 })
    }
}

// MARK: - Parsing (§7 tabs)

@Suite("App settings parsing")
struct AppPreferencesParsingTests {
    @Test func unsetKeysTakeTheWebDefaults() {
        let preferences = AppPreferences(values: [:])
        #expect(preferences.externalAvatars)
        #expect(!preferences.searchPriorityBody)
        #expect(preferences.autoMarkAsRead == .afterThreeSeconds)
        #expect(!preferences.replyAtBottom)
        #expect(preferences.collectData)
        #expect(!preferences.highlightExternal)
        #expect(preferences.followUpReminders)
        #expect(preferences.contextChat)
        #expect(!preferences.showAllMessagesInThread)
    }

    @Test func storedValuesAreReadAsTheWebReadsThem() {
        let preferences = AppPreferences(values: [
            "external-avatars": "false", "search-priority-body": "true", "auto-mark-as-read": "-1",
            "reply-mode": "bottom", "collect-data": "false", "internal-addresses": "true",
            "follow-up-reminders": "false", "index-context-chat": "false", "layout-message-view": "threaded",
        ])
        #expect(!preferences.externalAvatars)
        #expect(preferences.searchPriorityBody)
        #expect(preferences.autoMarkAsRead == .manually)
        #expect(preferences.replyAtBottom)
        #expect(!preferences.collectData)
        #expect(preferences.highlightExternal)
        #expect(!preferences.followUpReminders)
        #expect(!preferences.contextChat)
        #expect(preferences.showAllMessagesInThread)
    }

    @Test func anUnknownMarkAsReadValueFallsBackToThreeSeconds() {
        #expect(AppPreferences(values: ["auto-mark-as-read": "12345"]).autoMarkAsRead == .afterThreeSeconds)
        #expect(AutoMarkAsRead.afterThirtySeconds.localDelay == .after(seconds: 30))
        #expect(AutoMarkAsRead.manually.localDelay == .manually)
    }

    @Test func internalAddressInputNamesADomainOrAPerson() {
        #expect(InternalAddressInput.parse("@Example.com") == .init(address: "example.com", type: "domain"))
        #expect(InternalAddressInput.parse(" a@b.org ") == .init(address: "a@b.org", type: "individual"))
        #expect(InternalAddressInput.parse("b.org") == .init(address: "b.org", type: "domain"))
        #expect(InternalAddressInput.parse("") == nil)
        #expect(InternalAddressInput.parse("@") == nil)
        #expect(InternalAddressInput.parse("a@b@c") == nil)
        #expect(InternalAddressInput.parse("a b@c") == nil)
    }

    @Test func internalAddressesListDomainsFirst() {
        let sorted = InternalAddressInput.sorted([
            InternalAddressRecord(loginId: 1, address: "zed@a.org", type: "individual"),
            InternalAddressRecord(loginId: 1, address: "b.org", type: "domain"),
            InternalAddressRecord(loginId: 1, address: "amy@a.org", type: "individual"),
            InternalAddressRecord(loginId: 1, address: "a.org", type: "domain"),
        ])
        #expect(sorted.map(\.address) == ["a.org", "b.org", "amy@a.org", "zed@a.org"])
    }

    @Test func shareeSuggestionsDropSelfAndExistingSharesUsersFirst() {
        let payload = AnyJSON.array([
            .object(["shareWith": .string("admins"), "type": .string("group"), "displayName": .string("Admins")]),
            .object(["shareWith": .string("Admin"), "type": .string("user"), "displayName": .string("Me")]),
            .object(["shareWith": .string("bob"), "type": .string("user"), "displayName": .string("Bob")]),
            .object(["shareWith": .string("carol"), "type": .string("user")]),
            .object(["shareWith": .string("bob"), "type": .string("user"), "displayName": .string("Bob")]),
        ])
        let suggestions = ShareeSuggestion.suggestions(from: payload, excluding: ["carol"], selfUserId: "admin")
        #expect(suggestions.map(\.id) == ["user:bob", "group:admins"])
        #expect(ShareeSuggestion.suggestions(from: nil, excluding: [], selfUserId: "x").isEmpty)
    }

    @Test func textBlockPreviewIsOneLineOfText() {
        #expect(
            TextBlockFormatting.preview("<p>Hello&nbsp;<b>there</b></p><p>Bye &amp; thanks</p>")
                == "Hello there Bye & thanks")
    }

    @Test func certificateNamesFallBackToTheAddress() {
        let named = SmimeCertificateRow(
            SmimeCertificateRecord(
                loginId: 1, remoteId: 3, emailAddress: "a@b.org", notAfter: 86_400, infoJSON: #"{"commonName":"Ann"}"#))
        #expect(named.name == "Ann")
        #expect(named.validUntil == Date(timeIntervalSince1970: 86_400))
        let unnamed = SmimeCertificateRow(SmimeCertificateRecord(loginId: 1, remoteId: 4, emailAddress: "c@d.org"))
        #expect(unnamed.name == "c@d.org")
        #expect(unnamed.validUntil == nil)
    }

    @Test func importOutcomesUseTheWebWording() {
        #expect(SmimeImportResult(.success, hadPrivateKey: true).message == "Certificate imported successfully")
        // What the server answers a mismatched key with (live, 2026-10-04): a 500.
        #expect(
            SmimeImportResult(.failure(.server(status: 500, message: nil)), hadPrivateKey: true).message
                == "Failed to import the certificate. Please make sure that the private key matches the certificate and is not protected by a passphrase."
        )
        #expect(
            SmimeImportResult(.failure(.server(status: 500, message: nil)), hadPrivateKey: false).message
                == "Failed to import the certificate")
    }
}

// MARK: - The model over a real store and queue

@MainActor
@Suite("App settings model")
struct AppSettingsModelTests {
    let store: MailStore
    let first = ServerIdentity(serverURL: "https://one.example.com", loginName: "lorelai")
    let second = ServerIdentity(serverURL: "https://two.example.com", loginName: "rory")

    init() throws {
        store = try MailStore.inMemory()
    }

    /// Commands the model ran, in order.
    final class Recorder {
        var commands: [SettingsCommand] = []
        var shareeSearches: [String] = []
    }

    private func makeModel(recorder: Recorder = Recorder(), outcome: CommandOutcome = .success) -> AppSettingsModel {
        let store = store
        let list = MessageListPreferenceStore(store: store) { _ in MutationQueue(store: store) }
        return AppSettingsModel(
            store: store, listPreferences: list,
            services: AppSettingsServices(
                queue: { _ in MutationQueue(store: store) },
                run: { _, command in
                    recorder.commands.append(command)
                    return outcome
                },
                searchSharees: { _, term in recorder.shareeSearches.append(term) }
            ))
    }

    @discardableResult
    private func seed(_ identities: [ServerIdentity]) async throws -> [Int64] {
        var ids: [Int64] = []
        for (index, identity) in identities.enumerated() {
            let login = try await store.ensureLogin(identity)
            _ = try await store.upsert(accounts: [
                AccountWrite(
                    identity: identity, remoteId: Int64(index + 1), name: identity.loginName,
                    emailAddress: "\(identity.loginName)@example.com")
            ])
            ids.append(try #require(login.id))
        }
        return ids
    }

    @Test func switchesReadTheFirstLoginAndWriteEveryLogin() async throws {
        let ids = try await seed([first, second])
        try await store.setPreference(key: "collect-data", value: "false", loginId: ids[0], fetchedAt: 1)
        try await store.setPreference(key: "collect-data", value: "true", loginId: ids[1], fetchedAt: 1)
        let model = makeModel()
        model.start()
        defer { model.stop() }
        #expect(await settled { model.logins.count == 2 && !model.preferences.collectData })

        await model.setBool(AppPreferences.contextChatKey, false)
        #expect(await settled { !model.preferences.contextChat })
        for id in ids {
            #expect(try await store.preferenceValue(key: "index-context-chat", loginId: id) == "false")
        }
        #expect(model.errorMessage == nil)
    }

    @Test func markAsReadWritesThePreferenceAndTheLocalDelay() async throws {
        let ids = try await seed([first])
        let model = makeModel()
        model.start()
        defer { model.stop() }
        #expect(await settled { !model.logins.isEmpty })

        await model.setAutoMarkAsRead(.afterThirtySeconds)
        #expect(try await store.preferenceValue(key: "auto-mark-as-read", loginId: ids[0]) == "30000")
        let local = try await store.metaValue(forKey: MarkAsReadDelay.metaKey)
        #expect(MarkAsReadDelay(metaValue: local) == .after(seconds: 30))
        #expect(await settled { model.preferences.autoMarkAsRead == .afterThirtySeconds })
    }

    @Test func listsFollowTheSelectedLogin() async throws {
        let ids = try await seed([first, second])
        try await store.replaceTrustedSenders(
            [TrustedSenderRecord(loginId: ids[0], email: "one.example", type: "domain")], loginId: ids[0])
        try await store.replaceTrustedSenders(
            [TrustedSenderRecord(loginId: ids[1], email: "x@two.example", type: "individual")], loginId: ids[1])
        let model = makeModel()
        model.start()
        defer { model.stop() }
        #expect(await settled { model.trustedSenders.map(\.email) == ["one.example"] })
        model.selectedLoginId = ids[1]
        #expect(await settled { model.trustedSenders.map(\.email) == ["x@two.example"] })
    }

    @Test func removingATrustedSenderGoesThroughTheQueue() async throws {
        let ids = try await seed([first])
        try await store.replaceTrustedSenders(
            [
                TrustedSenderRecord(loginId: ids[0], email: "one.example", type: "domain"),
                TrustedSenderRecord(loginId: ids[0], email: "ann@else.example", type: "individual"),
            ], loginId: ids[0])
        let model = makeModel()
        model.start()
        defer { model.stop() }
        #expect(await settled { model.trustedSenders.count == 2 })

        for sender in model.trustedSenders {
            await model.removeTrustedSender(sender)
        }
        #expect(await settled { model.trustedSenders.isEmpty })
        let pending = try await store.pendingOperations(
            accountId: try #require(try await store.accounts(identity: first).first?.id))
        #expect(pending.count == 2)
        #expect(model.errorMessage == nil)
    }

    @Test func internalAddressesAreAddedAndRemovedThroughTheQueue() async throws {
        try await seed([first])
        let model = makeModel()
        model.start()
        defer { model.stop() }
        #expect(await settled { !model.logins.isEmpty })

        #expect(!(await model.addInternalAddress("not an address")))
        #expect(await model.addInternalAddress("@Corp.example"))
        #expect(await model.addInternalAddress("boss@else.example"))
        #expect(await settled { model.internalAddresses.map(\.address) == ["corp.example", "boss@else.example"] })
        if let domain = model.internalAddresses.first {
            await model.removeInternalAddress(domain)
        }
        #expect(await settled { model.internalAddresses.map(\.address) == ["boss@else.example"] })
    }

    @Test func textBlocksAreCreatedSharedAndDeletedThroughTheQueue() async throws {
        try await seed([first])
        let model = makeModel()
        model.start()
        defer { model.stop() }
        #expect(await settled { !model.logins.isEmpty })

        #expect(await model.createTextBlock(title: "Greeting", content: "<p>Hello</p>"))
        #expect(await settled { model.ownTextBlocks.map(\.title) == ["Greeting"] })
        let block = try #require(model.ownTextBlocks.first)
        #expect(block.remoteId < 0)

        let bob = ShareeSuggestion(shareWith: "bob", type: "user", displayName: "Bob")
        let team = ShareeSuggestion(shareWith: "team", type: "group", displayName: "Team")
        #expect(await model.share(block, with: team))
        #expect(await model.share(block, with: bob))
        #expect(await settled { model.shares(of: block).map(\.shareWith) == ["bob", "team"] })

        let bobShare = try #require(model.shares(of: block).first)
        #expect(await model.unshare(block, share: bobShare))
        #expect(await settled { model.shares(of: block).map(\.shareWith) == ["team"] })

        #expect(await model.updateTextBlock(block, title: "Hi", content: "<p>Hi</p>"))
        #expect(await settled { model.ownTextBlocks.first?.title == "Hi" })
        await model.deleteTextBlock(try #require(model.ownTextBlocks.first))
        #expect(await settled { model.ownTextBlocks.isEmpty })
    }

    @Test func shareeSearchAsksTheFetcherAndReadsTheRow() async throws {
        let ids = try await seed([first])
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.start()
        defer { model.stop() }
        #expect(await settled { !model.logins.isEmpty })

        model.searchSharees("bo", for: nil)
        #expect(await settled { recorder.shareeSearches == ["bo"] })
        let payload =
            #"{"status":"ready","data":[{"shareWith":"bob","type":"user","displayName":"Bob"},{"shareWith":"lorelai","type":"user","displayName":"Me"},{"shareWith":"board","type":"group","displayName":"Board"}]}"#
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: ids[0], kind: ServerResultKind.sharees.rawValue, key: "bo", payloadJSON: payload, fetchedAt: 1)
        )
        #expect(await settled { model.sharees.map(\.shareWith) == ["bob", "board"] })
        model.clearSharees()
        #expect(model.sharees.isEmpty)
    }

    @Test func aPKCS12ImportUploadsPEMOnly() async throws {
        try await seed([first])
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.start()
        defer { model.stop() }
        #expect(await settled { !model.logins.isEmpty })

        let data = try SmimeCertificateConverterTests.fixture("smime-rsa.p12")
        #expect(await model.importPKCS12(data, password: SmimeCertificateConverterTests.password) == .imported)
        guard case .importSMIME(let pem, let key)? = recorder.commands.first else {
            Issue.record("no importSMIME command")
            return
        }
        let certificate = String(decoding: pem, as: UTF8.self)
        let privateKey = String(decoding: try #require(key), as: UTF8.self)
        #expect(certificate.hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(privateKey.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
        // The password never leaves the device.
        #expect(!certificate.contains(SmimeCertificateConverterTests.password))
        #expect(!privateKey.contains(SmimeCertificateConverterTests.password))

        let wrong = await model.importPKCS12(data, password: "nope")
        #expect(wrong == .failed("Failed to import the certificate. Please check the password."))
        #expect(recorder.commands.count == 1)
    }

    @Test func capabilityFlagsGateAssistanceAndContextChat() async throws {
        try await seed([first])
        let model = makeModel()
        model.start()
        defer { model.stop() }
        #expect(await settled { !model.logins.isEmpty })
        #expect(model.followUpAvailable && model.contextChatAvailable)

        var login = try #require(try await store.login(for: first))
        login.contextChatAvailable = false
        login.llmFollowupAvailable = false
        try await store.update(login: login)
        #expect(await settled { !model.contextChatAvailable && !model.followUpAvailable })
    }

    /// Clock-bound at the in-tree 10 s: a full parallel run was measured missing five
    /// seconds here. Only a failing run waits this long.
    private func settled(_ condition: () -> Bool, seconds: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
