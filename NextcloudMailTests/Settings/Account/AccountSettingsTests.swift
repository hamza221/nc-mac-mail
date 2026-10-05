// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

private let identity = ServerIdentity(serverURL: "https://cloud.example.com", loginName: "lorelai")

private func account(
    rawJSON: String = "{}", sieveEnabled: Bool = false, provisioningId: Int64? = nil, isDelegated: Bool = false,
    editorMode: String? = nil
) -> AccountRecord {
    AccountRecord(
        id: 1, identity: identity, remoteId: 1, name: "Lorelai", emailAddress: "lorelai@example.com",
        rawJSON: rawJSON, editorMode: editorMode, sieveEnabled: sieveEnabled, provisioningId: provisioningId,
        isDelegated: isDelegated)
}

// MARK: - Section list (§8, §9)

@Suite("Account settings sections")
struct AccountSettingsSectionTests {
    @Test func aPlainAccountListsEverythingButCalendarAndScript() {
        let sections = AccountSettingsSection.visible(for: account())
        #expect(!sections.contains(.calendar))
        #expect(!sections.contains(.sieveScript))
        #expect(sections.contains(.autoresponder) && sections.contains(.filters))
        #expect(sections.contains(.mailServer) && sections.contains(.delegation))
    }

    @Test func theCalendarSwitchFollowsThePayloadAndTheScriptFollowsSieve() {
        let sections = AccountSettingsSection.visible(
            for: account(rawJSON: #"{"imipCreate":false}"#, sieveEnabled: true))
        #expect(sections.contains(.calendar))
        #expect(sections.contains(.sieveScript))
    }

    @Test func aDelegatedAccountHasNoMailServerAndNoDelegation() {
        let sections = AccountSettingsSection.visible(for: account(isDelegated: true))
        #expect(!sections.contains(.mailServer))
        #expect(!sections.contains(.delegation))
    }

    @Test func aProvisionedAccountLocksBothServersAndHidesDelegation() {
        let provisioned = account(provisioningId: 3)
        let sections = AccountSettingsSection.visible(for: provisioned)
        #expect(!sections.contains(.delegation))
        #expect(AccountSettingsSection.mailServer.isLocked(for: provisioned))
        #expect(AccountSettingsSection.sieveServer.isLocked(for: provisioned))
        #expect(!AccountSettingsSection.aliases.isLocked(for: provisioned))
        #expect(!AccountSettingsSection.mailServer.isLocked(for: account()))
    }
}

// MARK: - Pages (the Accounts tab's navigation)

@Suite("Account settings pages")
struct AccountSettingsGroupTests {
    private let accounts = [
        account(),
        account(rawJSON: #"{"imipCreate":false}"#, sieveEnabled: true),
        account(isDelegated: true),
        account(provisioningId: 3),
        account(rawJSON: #"{"imipCreate":true}"#, sieveEnabled: true, provisioningId: 3, isDelegated: true),
    ]

    @Test func everySectionIsOnExactlyOnePage() {
        for section in AccountSettingsSection.allCases {
            let pages = AccountSettingsGroup.allCases.filter { $0.sections.contains(section) }
            #expect(pages == [AccountSettingsGroup.containing(section)], "\(section)")
        }
        let listed = AccountSettingsGroup.allCases.flatMap(\.sections)
        #expect(listed.count == AccountSettingsSection.allCases.count)
        #expect(Set(listed) == Set(AccountSettingsSection.allCases))
    }

    @Test func thePagesGroupTheSectionsAsListed() {
        let general: [AccountSettingsSection] = [.aliases, .certificates, .writingMode, .classification, .calendar]
        #expect(AccountSettingsGroup.general.sections == general)
        #expect(AccountSettingsGroup.signature.sections == [.signature])
        #expect(AccountSettingsGroup.folders.sections == [.defaultFolders, .trashRetention, .folderSearch])
        #expect(AccountSettingsGroup.autoresponder.sections == [.autoresponder])
        #expect(AccountSettingsGroup.filters.sections == [.filters])
        #expect(AccountSettingsGroup.quickActions.sections == [.quickActions])
        #expect(AccountSettingsGroup.mailServer.sections == [.mailServer])
        #expect(AccountSettingsGroup.sieve.sections == [.sieveServer, .sieveScript])
        #expect(AccountSettingsGroup.delegation.sections == [.delegation])
    }

    @Test func aSectionWithItsOwnFormIsAloneOnItsPage() {
        for group in AccountSettingsGroup.allCases where group.sections.contains(where: \.ownsForm) {
            #expect(group.sections.count == 1, "\(group)")
        }
    }

    @Test func theVisiblePagesReachEveryVisibleSectionAndNothingElse() {
        for account in accounts {
            let visible = AccountSettingsSection.visible(for: account)
            let pages = AccountSettingsGroup.visible(for: account)
            let reached = pages.flatMap { $0.sections.filter(visible.contains) }
            #expect(reached == pages.flatMap(\.sections).filter(visible.contains))
            #expect(Set(reached) == Set(visible))
            for page in pages {
                #expect(page.sections.contains(where: visible.contains), "\(page) is empty")
            }
        }
    }

    @Test func aPlainAccountShowsEveryPage() {
        #expect(AccountSettingsGroup.visible(for: account()) == AccountSettingsGroup.allCases)
    }

    @Test func aDelegatedAccountFallsBackToGeneralForThePagesItLacks() {
        let delegated = account(isDelegated: true)
        let pages = AccountSettingsGroup.visible(for: delegated)
        #expect(!pages.contains(.mailServer) && !pages.contains(.delegation))
        #expect(AccountSettingsGroup.mailServer.resolved(for: delegated) == .general)
        #expect(AccountSettingsGroup.delegation.resolved(for: delegated) == .general)
        #expect(AccountSettingsGroup.sieve.resolved(for: delegated) == .sieve)
        #expect(AccountSettingsGroup.delegation.resolved(for: account()) == .delegation)
    }

    @Test func theGoToLinksLandOnAVisiblePage() {
        // Aliases' "Edit" goes to Mail server; Autoresponder's and Filters' hint to Sieve.
        #expect(AccountSettingsGroup.containing(.mailServer) == .mailServer)
        #expect(AccountSettingsGroup.containing(.sieveServer) == .sieve)
        for account in accounts {
            let pages = AccountSettingsGroup.visible(for: account)
            #expect(pages.contains(.sieve))
            #expect(pages.contains(.mailServer) == AccountSettingsSection.visible(for: account).contains(.mailServer))
        }
    }
}

// MARK: - Quick actions (§8.7)

@Suite("Quick action terminal-step rules")
struct QuickActionDraftTests {
    @Test func aTerminalStepStaysLastAndLaterStepsGoBeforeIt() {
        var draft = QuickActionDraft(name: "Tidy")
        draft.add(QuickActionStep.markAsRead)
        draft.add(QuickActionStep.moveThread)
        draft.add(QuickActionStep.applyTag)
        #expect(
            draft.steps.map(\.name) == [
                QuickActionStep.markAsRead, QuickActionStep.applyTag, QuickActionStep.moveThread,
            ])
    }

    @Test func onlyOneTerminalStepIsOffered() {
        var draft = QuickActionDraft(name: "Spam")
        #expect(draft.addableStepNames == QuickActionDraft.allStepNames)
        draft.add(QuickActionStep.markAsSpam)
        #expect(!draft.addableStepNames.contains(where: QuickActionStep.isTerminal))
        #expect(draft.add(QuickActionStep.deleteThread) == nil)
        #expect(draft.steps.count == 1)
    }

    @Test func theTerminalStepNeitherMovesNorIsJumped() {
        var draft = QuickActionDraft(name: "x")
        draft.add(QuickActionStep.markAsRead)
        draft.add(QuickActionStep.markAsFavorite)
        draft.add(QuickActionStep.deleteThread)
        let read = draft.steps[0].id
        let favorite = draft.steps[1].id
        let delete = draft.steps[2].id
        #expect(!draft.canMove(delete, by: -1))
        #expect(!draft.canMove(favorite, by: 1))
        #expect(draft.canMove(favorite, by: -1))
        draft.move(favorite, by: -1)
        #expect(draft.steps.map(\.id) == [favorite, read, delete])
    }

    @Test func saveNeedsANameAStepAndEveryChoice() {
        var draft = QuickActionDraft(name: " ")
        draft.add(QuickActionStep.applyTag)
        #expect(!draft.canSave)
        draft.name = "Tag it"
        #expect(!draft.canSave)
        draft.steps[0].tagRemoteId = 4
        #expect(draft.canSave)
    }

    @Test func onlyNewAndChangedStepsAreWritten() {
        let saved = QuickActionDraft(
            remoteId: 9, name: "x",
            steps: [
                .init(remoteId: 1, name: QuickActionStep.markAsRead),
                .init(remoteId: 2, name: QuickActionStep.applyTag, tagRemoteId: 5),
            ])
        var edited = saved
        edited.steps[1].tagRemoteId = 6
        edited.add(QuickActionStep.markAsFavorite)
        let writes = edited.stepWrites(comparedTo: saved)
        #expect(writes.map(\.step.remoteId) == [2, nil])
        #expect(writes.map(\.order) == [2, 3])
    }
}

// MARK: - Filters (§8.6)

@Suite("Mail filter (de)serialisation")
struct MailFilterDraftTests {
    /// The shape the live server stored and answered (Mail 5.12, 2026-10-04), including a
    /// key the editor does not model.
    static let live = #"""
        [{"name":"WS39 all kinds","enable":true,"operator":"anyof","priority":20,
          "tests":[{"field":"from","operator":"matches","values":["*@ws39.example"]},
                   {"field":"to","operator":"is","values":["a@b.c"]}],
          "actions":[{"type":"addsystemflag","flag":"\\Seen"},{"type":"fileinto","mailbox":"INBOX"},
                     {"type":"redirect","to":"x@example.com"},{"type":"stop"}],
          "x-unknown":"kept"}]
        """#

    @Test func parsesEveryModelledField() throws {
        let filter = try #require(MailFilterDraft.parse(Self.live)?.first)
        #expect(filter.name == "WS39 all kinds")
        #expect(filter.enable)
        #expect(filter.operator == .any)
        #expect(filter.priority == 20)
        #expect(filter.conditions.map(\.field) == [.from, .to])
        #expect(filter.conditions.map(\.match) == [.matches, .is])
        #expect(filter.actions.map(\.kind) == [.addSystemFlag, .fileInto, nil, .stop])
        #expect(filter.actions[0].value == "\\Seen")
        #expect(filter.actions[1].value == "INBOX")
    }

    @Test func writesBackWhatItReadIncludingUnknownKeys() throws {
        guard case .array(let items) = try JSONDecoder().decode(AnyJSON.self, from: Data(Self.live.utf8)) else {
            Issue.record("fixture is not an array")
            return
        }
        let original = try #require(items.first)
        let filter = try #require(MailFilterDraft.parse(Self.live)?.first)
        #expect(filter.json == original)
    }

    @Test func noFiltersYetIsNilAndAnEmptyListIsEmpty() {
        #expect(MailFilterDraft.parse(nil) == nil)
        #expect(MailFilterDraft.parse("[]") == [])
    }

    @Test func aNewFilterRunsAfterTheOthers() {
        let existing = MailFilterDraft.parse(Self.live) ?? []
        let fresh = MailFilterDraft.new(after: existing)
        #expect(fresh.priority == 30)
        #expect(fresh.enable && fresh.operator == .all)
        #expect(fresh.conditions.map(\.match) == [.is])
        #expect(fresh.actions.map(\.kind) == [.fileInto])
        #expect(!fresh.isValid)
    }

    @Test func stopStaysLastAndChangingKindDropsTheValue() throws {
        var filter = try #require(MailFilterDraft.parse(Self.live)?.first)
        filter.addAction()
        #expect(filter.actions.last?.kind == .stop)
        filter.actions[1].change(to: .addFlag)
        #expect(filter.actions[1].value.isEmpty)
        #expect(MailFilterDraft.values(from: " a, b ,,c ") == ["a", "b", "c"])
    }
}

// MARK: - Autoresponder (§8.4)

@Suite("Autoresponder form")
struct OutOfOfficeDraftTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return calendar
    }

    @Test func readsTheServersStateBackAsDays() throws {
        let sieve = SieveStateRecord(
            accountId: 1,
            outOfOfficeJSON:
                #"{"enabled":true,"start":"2026-10-04T22:00:00+00:00","end":"2026-10-11T22:00:00+00:00","subject":"Away","message":"Back soon"}"#,
            fetchedAt: 0
        )
        let draft = OutOfOfficeDraft(account: account(), sieve: sieve, now: Date(), calendar: calendar)
        #expect(draft.mode == .on)
        let first = calendar.dateComponents([.month, .day], from: draft.firstDay)
        let last = calendar.dateComponents([.month, .day], from: try #require(draft.lastDay))
        #expect(first.month == 10 && first.day == 5)
        #expect(last.month == 10 && last.day == 11)
    }

    @Test func lastDayStartsSixDaysLaterAndKeepsTheGap() throws {
        var draft = OutOfOfficeDraft(firstDay: Date(timeIntervalSince1970: 1_790_000_000))
        draft.setHasLastDay(true, calendar: calendar)
        let gap = calendar.dateComponents([.day], from: draft.firstDay, to: try #require(draft.lastDay)).day
        #expect(gap == 6)
        draft.setFirstDay(draft.firstDay.addingTimeInterval(2 * 86_400), calendar: calendar)
        let kept = calendar.dateComponents([.day], from: draft.firstDay, to: try #require(draft.lastDay)).day
        #expect(kept == 6)
    }

    @Test func onNeedsSubjectAndMessageButOffAlwaysSaves() {
        var draft = OutOfOfficeDraft(firstDay: Date())
        #expect(draft.canSave)
        draft.mode = .on
        #expect(!draft.canSave)
        draft.subject = "Away"
        draft.message = "Back soon"
        #expect(draft.canSave)
    }

    @Test func followSystemIsItsOwnCommand() {
        var draft = OutOfOfficeDraft(firstDay: Date())
        draft.mode = .followSystem
        guard case .followSystemOutOfOffice(accountId: 1) = draft.command(accountId: 1) else {
            Issue.record("expected followSystemOutOfOffice")
            return
        }
    }
}

// MARK: - Small rules

@Suite("Account settings rules")
struct AccountSettingsRulesTests {
    @Test func trashRetentionTreatsEmptyAsZero() {
        #expect(TrashRetention.days(from: "") == 0)
        #expect(TrashRetention.days(from: " 14 ") == 14)
        #expect(TrashRetention.days(from: "-1") == nil)
        #expect(TrashRetention.days(from: "two") == nil)
        #expect(TrashRetention.text(nil).isEmpty)
        #expect(TrashRetention.text(0).isEmpty)
        #expect(TrashRetention.text(7) == "7")
    }

    @Test func signatureWarnings() {
        #expect(SignatureRules.isLarge(String(repeating: "a", count: SignatureRules.largeSignatureBytes + 1)))
        #expect(!SignatureRules.isLarge("Lorelai"))
        let withImage = #"<p>Hi</p><img src="data:image/png;base64,AAAA">"#
        #expect(SignatureRules.overridesPlainText(withImage, editorMode: AccountEditorMode.plain))
        #expect(!SignatureRules.overridesPlainText(withImage, editorMode: AccountEditorMode.rich))
    }

    /// The recorded 422 body: the parser's message, JSON-encoded inside `message`.
    @Test func aSieve422ShowsTheParsersMessageUnquoted() throws {
        let body = try JSONDecoder().decode(
            [String: String].self, from: try FixtureBytes.data("error-sieve-script-422.json"))
        let outcome = CommandOutcome.failure(.server(status: 422, message: body["message"]))
        #expect(
            CommandMessage.sieveScriptFailure(outcome)
                == "Oh Snap! The syntax seems to be incorrect: Expected token \"command\" but found \"this\" at line 0, column 0."
        )
        #expect(CommandMessage.sieveScriptFailure(.success) == nil)
    }

    @Test func aBlankPasswordKeepsTheStoredOne() {
        let raw =
            #"{"imapHost":"mail.example.com","imapPort":993,"imapSslMode":"ssl","imapUser":"u","smtpHost":"mail.example.com","smtpPort":"465","smtpSslMode":"ssl","smtpUser":"u","authMethod":"password"}"#
        var draft = MailServerDraft(account: account(rawJSON: raw))
        #expect(draft.smtpPort == 465)
        #expect(draft.isValid)
        #expect(draft.request.imapPassword == nil)
        draft.smtpPassword = "secret"
        #expect(draft.request.smtpPassword == "secret")
        #expect(!draft.usesOAuth)
    }

    @Test func sieveDefaultsToTheIMAPHostOnStartTLS() {
        let raw = #"{"imapHost":"mail.example.com","imapUser":"u"}"#
        var draft = SieveServerDraft(account: account(rawJSON: raw), sieve: nil)
        #expect(draft.host == "mail.example.com")
        #expect(draft.port == 4190)
        #expect(draft.security == .tls)
        #expect(!draft.customCredentials)
        draft.enabled = true
        #expect(draft.request.sieveUser.isEmpty)
        draft.enabled = false
        #expect(draft.request.sieveEnabled == false)
    }

    @Test func delegateSearchKeepsOtherUsersOnly() {
        let payload =
            #"{"status":"ready","data":[{"type":"user","shareWith":"rory","displayName":"Rory"},{"type":"group","shareWith":"staff"},{"type":"user","shareWith":"lorelai"},{"type":"user","shareWith":"luke"}]}"#
        let row = ServerResultRecord(loginId: 1, kind: "sharees", key: "r", payloadJSON: payload, fetchedAt: 0)
        let users = AccountSettingsModel.users(in: row, excluding: ["lorelai", "luke"])
        #expect(users == [AccountSettingsModel.Sharee(userId: "rory", displayName: "Rory")])
    }
}

// MARK: - The model over a real queue

@MainActor
@Suite("Account settings model")
struct AccountSettingsModelTests {
    @Test func aNewQuickActionAndItsStepsAreQueuedAgainstThePlaceholder() async throws {
        let store = try MailStore.inMemory()
        let records = try await store.upsert(
            accounts: [AccountWrite(identity: identity, remoteId: 1, name: "Work", emailAddress: "l@example.com")])
        let accountId = try #require(records.first?.id)
        let model = AccountSettingsModel(
            accountId: accountId, store: store,
            services: AccountSettingsServices(
                queue: { _ in MutationQueue(store: store) },
                run: { _, _ in .success },
                searchSharees: { _, _ in }
            ))

        var draft = QuickActionDraft(name: "Read and star")
        draft.add(QuickActionStep.markAsRead)
        draft.add(QuickActionStep.markAsFavorite)
        #expect(await model.save(draft, original: nil))

        let action = try #require(try await store.quickActions(accountId: accountId).first)
        #expect(action.name == "Read and star")
        #expect(action.remoteId < 0)
        let steps = try await store.quickActionSteps(accountId: accountId)[try #require(action.id)] ?? []
        #expect(steps.map(\.name) == [QuickActionStep.markAsRead, QuickActionStep.markAsFavorite])
        #expect(steps.map(\.position) == [1, 2])
        #expect(model.queueError == nil)
    }

    @Test func aMissingQueueIsALocalError() async throws {
        let store = try MailStore.inMemory()
        let model = AccountSettingsModel(
            accountId: 1, store: store,
            services: AccountSettingsServices(
                queue: { _ in nil }, run: { _, _ in .success }, searchSharees: { _, _ in }))
        #expect(await model.perform(.setSignature("x")) == false)
        #expect(model.queueError != nil)
    }
}
