// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// Every §7 write, through `AppSettingsModel`, against a live server: queued writes drained,
/// commands run for real, and each result read back from the server through a fresh
/// `ServerStateMirror` pass. Everything the test creates is removed, and every switch it
/// flips is put back.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   NCMAIL_LIVE_SHARE_USER=alice \
///   xcodebuild test -project NextcloudMail.xcodeproj -scheme NextcloudMail \
///   -destination 'platform=macOS' -only-testing:NextcloudMailTests/AppSettingsLiveTests
/// ```
@MainActor
@Suite("App settings against a live server")
struct AppSettingsLiveTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static var hasLiveServer: Bool { environment["NCMAIL_LIVE_MIRROR"] != nil }

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: AppSettingsLiveTests.hasLiveServer))
    func everyAppSettingWritesThroughToTheServer() async throws {
        guard
            let raw = Self.environment["NCMAIL_LIVE_MIRROR"], let server = URL(string: raw),
            let user = Self.environment["NCMAIL_LIVE_USER"],
            let password = Self.environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let store = try MailStore.inMemory()
        let client = MailClient(
            server: server, credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "app-settings-live-test")
        let identity = ServerIdentity(serverURL: server, loginName: user)
        let loginId = try #require(try await store.ensureLogin(identity).id)
        let discovered = try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity)
        let accountId = try #require(discovered.first?.id)
        let mirror = ServerStateMirror(store: store, client: client, identity: identity)
        _ = await mirror.refresh(trigger: .settingsOpened)

        let commands = SettingsCommands(store: store, client: client, identity: identity)
        let fetcher = ServerResultFetcher(store: store, client: client, identity: identity)
        let list = MessageListPreferenceStore(store: store) { _ in MutationQueue(store: store) }
        let model = AppSettingsModel(
            store: store, listPreferences: list,
            services: AppSettingsServices(
                queue: { _ in MutationQueue(store: store) },
                run: { _, command in await commands.run(command) },
                searchSharees: { _, term in Task { await fetcher.request(kind: .sharees, key: term) } }
            ))
        model.start()
        defer { model.stop() }
        #expect(await settled { model.selectedLogin != nil })
        let drainer = OperationDrainer(store: store, client: client, accountId: accountId)

        /// Drain, then re-read everything from the server.
        func roundTrip() async throws {
            await drainer.drain()
            #expect(try await store.pendingOperations(accountId: accountId).isEmpty)
            _ = await mirror.refresh(trigger: .settingsOpened)
        }

        // §7 switches: Context Chat and data collection flipped, read back, restored.
        let original = model.preferences
        await model.setBool(AppPreferences.contextChatKey, !original.contextChat)
        await model.setBool(AppPreferences.collectDataKey, !original.collectData)
        try await roundTrip()
        #expect(
            await settled {
                model.preferences.contextChat == !original.contextChat
                    && model.preferences.collectData == !original.collectData
            })
        await model.setBool(AppPreferences.contextChatKey, original.contextChat)
        await model.setBool(AppPreferences.collectDataKey, original.collectData)
        try await roundTrip()
        #expect(
            try await store.preferenceValue(key: AppPreferences.contextChatKey, loginId: loginId)
                == String(original.contextChat))

        // Security: an internal domain added and removed.
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let domain = "ws38-\(suffix).example"
        #expect(await model.addInternalAddress("@\(domain)"))
        try await roundTrip()
        #expect(await settled { model.internalAddresses.contains { $0.address == domain && $0.type == "domain" } })
        let added = try #require(model.internalAddresses.first { $0.address == domain })
        await model.removeInternalAddress(added)
        try await roundTrip()
        #expect(await settled { !model.internalAddresses.contains { $0.address == domain } })

        // Privacy: a trusted sender (trusted the way the reader does it), then removed here.
        let sender = "ws38-\(suffix)@example.com"
        try await MutationQueue(store: store).perform(.trustSender(email: sender, trusted: true), loginId: loginId)
        try await roundTrip()
        #expect(await settled { model.trustedSenders.contains { $0.email == sender } })
        let trusted = try #require(model.trustedSenders.first { $0.email == sender })
        await model.removeTrustedSender(trusted)
        try await roundTrip()
        #expect(await settled { !model.trustedSenders.contains { $0.email == sender } })

        // §7.1: a text block, shared with a group the sharee search found, then unshared and gone.
        let title = "WS38 Live \(suffix)"
        #expect(await model.createTextBlock(title: title, content: "<p>Hello from WS-38</p>"))
        try await roundTrip()
        #expect(await settled { model.ownTextBlocks.contains { $0.title == title && $0.remoteId > 0 } })
        let block = try #require(model.ownTextBlocks.first { $0.title == title })
        // A mirror pass replaces the rows (new local ids); the remote id is what stays.
        func current() -> TextBlockRecord { model.ownTextBlocks.first { $0.remoteId == block.remoteId } ?? block }
        model.searchSharees("admin", for: block)
        #expect(await settled(seconds: 10) { model.sharees.contains { $0.type == "group" && $0.shareWith == "admin" } })
        let group = try #require(model.sharees.first { $0.type == "group" && $0.shareWith == "admin" })
        #expect(await model.share(block, with: group))
        if let shareUser = Self.environment["NCMAIL_LIVE_SHARE_USER"] {
            #expect(
                await model.share(
                    block, with: ShareeSuggestion(shareWith: shareUser, type: "user", displayName: shareUser)))
        }
        try await roundTrip()
        #expect(
            await settled { model.shares(of: current()).contains { $0.shareWith == "admin" && $0.type == "group" } })
        let remote = try await client.get(Endpoint.textBlockShares(textBlockId: Int(block.remoteId)))
        #expect(remote.data.contains { $0.shareWith == "admin" })
        let refreshed = current()
        for share in model.shares(of: refreshed) {
            #expect(await model.unshare(refreshed, share: share))
        }
        try await roundTrip()
        #expect(await settled { model.shares(of: current()).isEmpty })
        #expect(await model.updateTextBlock(current(), title: title + " edited", content: "<p>Edited</p>"))
        try await roundTrip()
        #expect(await settled { model.ownTextBlocks.contains { $0.title == title + " edited" } })
        await model.deleteTextBlock(try #require(model.ownTextBlocks.first { $0.remoteId == block.remoteId }))
        try await roundTrip()
        #expect(await settled { !model.ownTextBlocks.contains { $0.remoteId == block.remoteId } })

        // §7.2: a PKCS #12 converted here and uploaded as PEM; visible in GET smime-certificates.
        let p12 = try SmimeCertificateConverterTests.fixture("smime-rsa.p12")
        let before = try await client.get(Endpoint.smimeCertificates).data.map(\.id)
        #expect(await model.importPKCS12(p12, password: SmimeCertificateConverterTests.password) == .imported)
        let after = try await client.get(Endpoint.smimeCertificates).data
        let imported = try #require(after.first { !before.contains($0.id) })
        #expect(await settled { model.certificates.contains { $0.remoteId == Int64(imported.id) } })
        let row = try #require(model.certificates.first { $0.remoteId == Int64(imported.id) })
        #expect(row.name == "Lorelai Gilmore")

        // A key that does not belong to the certificate: the server's refusal, in the web's words.
        let pair = try SmimeCertificateConverter.pemPair(
            fromPKCS12: p12, password: SmimeCertificateConverterTests.password)
        let other = try SmimeCertificateConverter.pemPair(
            fromPKCS12: try SmimeCertificateConverterTests.fixture("smime-ec.p12"),
            password: SmimeCertificateConverterTests.password)
        let mismatched = await model.importPEM(certificate: pair.certificate, privateKey: other.privateKey)
        #expect(
            mismatched
                == .failed(
                    "Failed to import the certificate. Please make sure that the private key matches the certificate and is not protected by a passphrase."
                ))

        #expect(await model.deleteCertificate(row) == nil)
        #expect(await settled { !model.certificates.contains { $0.remoteId == Int64(imported.id) } })
        #expect(try await client.get(Endpoint.smimeCertificates).data.allSatisfy { $0.id != imported.id })
    }

    private func settled(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
