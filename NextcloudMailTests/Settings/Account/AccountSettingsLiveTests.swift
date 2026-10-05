// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// Every §8 section's write, through `AccountSettingsModel` and the section models, against a
/// live server: the queued ones drained, the commands run for real. Sieve is switched on for
/// the run and off again at the end (the recorder's lifecycle, ADR-0080), and everything the
/// test creates is deleted.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   NCMAIL_LIVE_DELEGATE=alice \
///   xcodebuild test -project NextcloudMail.xcodeproj -scheme NextcloudMail \
///   -destination 'platform=macOS' -only-testing:NextcloudMailTests/AccountSettingsLiveTests
/// ```
@MainActor
@Suite("Account settings against a live server")
struct AccountSettingsLiveTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static var hasLiveServer: Bool { environment["NCMAIL_LIVE_MIRROR"] != nil }

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: AccountSettingsLiveTests.hasLiveServer))
    func everySectionWritesThroughToTheServer() async throws {
        guard
            let raw = Self.environment["NCMAIL_LIVE_MIRROR"], let server = URL(string: raw),
            let user = Self.environment["NCMAIL_LIVE_USER"],
            let password = Self.environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let store = try MailStore.inMemory()
        let client = MailClient(
            server: server, credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "account-settings-live-test")
        let identity = ServerIdentity(serverURL: server, loginName: user)
        _ = try await store.ensureLogin(identity)
        let discovered = try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity)
        let accountId = try #require(discovered.first?.id)
        let remote = Int(try #require(discovered.first?.remoteId))
        let list = try await client.get(Endpoint.mailboxes(accountId: remote))
        try await store.upsert(
            mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: accountId) },
            accountId: accountId)

        let commands = SettingsCommands(store: store, client: client, identity: identity)
        let model = AccountSettingsModel(
            accountId: accountId, store: store,
            services: AccountSettingsServices(
                queue: { _ in MutationQueue(store: store) },
                run: { _, command in await commands.run(command) },
                searchSharees: { _, _ in }
            ))
        model.start()
        defer { model.stop() }
        #expect(await settled { model.account != nil && model.login != nil })
        let drainer = OperationDrainer(store: store, client: client, accountId: accountId)
        let original = try #require(model.account)

        // Queued §8.3 switches: written locally at once, on the server after the drain.
        await model.patch(AccountPatch(editorMode: AccountEditorMode.rich))
        await model.patch(AccountPatch(searchBody: !original.searchBody))
        #expect(await settled { model.account?.editorMode == AccountEditorMode.rich })
        await drainer.drain()
        // What the server now holds: a fresh discovery overwrites the mirror's row with it.
        let patched = try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity)
        #expect(patched.first?.editorMode == AccountEditorMode.rich)
        #expect(patched.first?.searchBody == !original.searchBody)
        #expect(try await store.pendingOperations(accountId: accountId).isEmpty)
        await model.patch(AccountPatch(editorMode: original.editorMode ?? AccountEditorMode.plain))
        await model.patch(AccountPatch(searchBody: original.searchBody))

        // §8.1: an alias through its placeholder, then gone again.
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let aliasAddress = "ws39-\(suffix)@example.com"
        #expect(await model.perform(.createAlias(email: aliasAddress, name: "WS39 Live")))
        await drainer.drain()
        #expect(await settled { model.aliases.contains { $0.email == aliasAddress && $0.remoteId > 0 } })
        if let alias = model.aliases.first(where: { $0.email == aliasAddress }) {
            await model.perform(.deleteAlias(aliasRemoteId: alias.remoteId))
        }

        // §8.7: a new action and its steps, queued against the placeholder.
        var action = QuickActionDraft(name: "WS39 Live \(suffix)")
        action.add(QuickActionStep.deleteThread)
        action.add(QuickActionStep.markAsRead)
        #expect(action.steps.map(\.name) == [QuickActionStep.markAsRead, QuickActionStep.deleteThread])
        #expect(await model.save(action, original: nil))
        await drainer.drain()
        #expect(try await store.pendingOperations(accountId: accountId).isEmpty)
        let savedAction = try #require(model.quickActions.first { $0.name == action.name })
        #expect(savedAction.remoteId > 0)
        #expect(model.steps(of: savedAction).map(\.name) == [QuickActionStep.markAsRead, QuickActionStep.deleteThread])
        await model.perform(.deleteQuickAction(quickActionRemoteId: savedAction.remoteId))
        await drainer.drain()
        #expect(try await store.pendingOperations(accountId: accountId).isEmpty)

        // Mail server: the account's own settings back, passwords blank. The re-read keeps
        // the writing mode and default folders the PUT's answer drops (server-findings 33).
        let before = try #require(try await store.account(id: accountId))
        let mailServer = MailServerDraft(account: before)
        #expect(mailServer.isValid)
        #expect(await model.run(.updateMailServer(accountId: accountId, mailServer.request)).isSuccess)
        let after = try #require(try await store.account(id: accountId))
        #expect(after.editorMode == before.editorMode)
        #expect(after.draftsMailboxId == before.draftsMailboxId)
        #expect(after.trashMailboxId == before.trashMailboxId)
        #expect(await model.run(.testConnection(accountId: accountId)).isSuccess)
        #expect(await settled { model.connectionOK == true })

        // §8.5: Sieve on, which brings the script editor into the list.
        var sieve = SieveServerDraft(account: after, sieve: model.sieve)
        sieve.enabled = true
        let sieveOn = await model.run(.configureSieve(accountId: accountId, sieve.request))
        #expect(sieveOn.isSuccess, "\(CommandMessage.failure(sieveOn) ?? "")")
        #expect(await settled { model.sections.contains(.sieveScript) && model.filters != nil })

        // §8.6: one filter of every kind the editor offers, read back through the mirror.
        var filter = MailFilterDraft.new(after: model.filters ?? [])
        filter.name = "WS39 Live \(suffix)"
        filter.conditions[0].values = ["ws39-\(suffix)"]
        filter.actions[0].value = "INBOX"
        filter.actions.append(
            .init(type: MailFilterDraft.ActionKind.addSystemFlag.rawValue, fields: ["flag": .string("\\Seen")]))
        filter.actions.append(.init(kind: .stop))
        filter.addAction()
        filter.actions.removeAll { $0.kind == .fileInto && $0.value.isEmpty }
        #expect(filter.actions.last?.kind == .stop)
        #expect(filter.isValid)
        #expect(await model.saveFilters((model.filters ?? []) + [filter]).isSuccess)
        #expect(await settled { model.filters?.contains { $0.name == filter.name } == true })
        let readBack = try #require(model.filters?.first { $0.name == filter.name })
        #expect(readBack.actions.map(\.kind) == [.fileInto, .addSystemFlag, .stop])

        // §8.4: on, read back as days; then off.
        var away = OutOfOfficeDraft(firstDay: Date())
        away.mode = .on
        away.setHasLastDay(true)
        away.subject = "WS39 away"
        away.message = "Back soon"
        let awayOutcome = await model.run(away.command(accountId: accountId))
        #expect(awayOutcome.isSuccess, "\(CommandMessage.failure(awayOutcome) ?? "")")
        #expect(
            await settled {
                guard let account = model.account else { return false }
                let draft = OutOfOfficeDraft(account: account, sieve: model.sieve, now: Date())
                return draft.mode == .on && draft.subject == "WS39 away" && draft.lastDay != nil
            })
        var off = OutOfOfficeDraft(firstDay: Date())
        off.mode = .off
        #expect(await model.run(off.command(accountId: accountId)).isSuccess)

        // §8.5: the parser's verdict, as the script editor shows it.
        let bad = await model.run(
            .saveSieveScript(accountId: accountId, script: "require [\"fileinto\"];\nthis is not sieve;\n"))
        let shown = try #require(CommandMessage.sieveScriptFailure(bad))
        #expect(shown.hasPrefix("Oh Snap! The syntax seems to be incorrect: Expected token"))
        #expect(!shown.contains("\"\""))

        // Clean up: the filter list as it was, Sieve off.
        let kept = (model.filters ?? []).filter { $0.name != filter.name }
        #expect(await model.saveFilters(kept).isSuccess)
        sieve.enabled = false
        #expect(await model.run(.configureSieve(accountId: accountId, sieve.request)).isSuccess)
        #expect(await settled { model.account?.sieveEnabled == false && !model.sections.contains(.sieveScript) })

        // §8.8: a real delegate, then revoked. Self-delegation is the server's refusal.
        #expect(!(await model.run(.delegate(accountId: accountId, userId: user)).isSuccess))
        if let delegate = Self.environment["NCMAIL_LIVE_DELEGATE"] {
            #expect(await model.run(.delegate(accountId: accountId, userId: delegate)).isSuccess)
            #expect(await settled { model.delegations.contains { $0.userId == delegate } })
            #expect(await model.run(.revokeDelegation(accountId: accountId, userId: delegate)).isSuccess)
            #expect(await settled { !model.delegations.contains { $0.userId == delegate } })
        }

        await drainer.drain()
        #expect(try await store.pendingOperations(accountId: accountId).isEmpty)
    }

    private func settled(_ condition: () -> Bool, seconds: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
