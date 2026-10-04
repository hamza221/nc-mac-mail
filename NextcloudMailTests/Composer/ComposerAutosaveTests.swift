// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// The composer's debounced local write: typing lands in the draft row without an error.
///
/// The write used to run inside the debounce task and cancel that task as its first step,
/// so the store's next await threw `CancellationError` and every autosave ended as
/// "Error saving draft" with no row written; only ⌘S, on a task of its own, got through.
@Suite("Composer autosave")
@MainActor
struct ComposerAutosaveTests {
    let store: MailStore
    let identity = ServerIdentity(serverURL: URL(string: "https://cloud.example.com")!, loginName: "me")

    init() throws {
        store = try MailStore.inMemory()
    }

    private func composer() async throws -> ComposerModel {
        let account = try #require(
            try await store.upsert(accounts: [
                AccountWrite(identity: identity, remoteId: 1, name: "Me", emailAddress: "me@example.com")
            ]).first)
        let session = ComposerServices(store: store, engine: AccountEngine(store: store, status: AppStatus()))
        let model = ComposerModel(request: .new(accountId: account.id, mailto: nil), session: session)
        await model.load(restoringDraftId: nil)
        #expect(model.phase == .editing)
        return model
    }

    private func waitForRow(_ model: ComposerModel, subject: String) async throws -> DraftRecord? {
        for _ in 0..<50 {
            if let id = model.draftId, let row = try await store.draft(id: id), row.subject == subject { return row }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @Test func typingIsWrittenToTheDraftRowWithoutAnError() async throws {
        let model = try await composer()
        defer { model.discard() }

        model.subject = "Lunch"
        let row = try await waitForRow(model, subject: "Lunch")
        #expect(row != nil)
        #expect(model.saveStatus != .failed(String(localized: "Error saving draft")))
    }

    @Test func anEditDuringAWriteDoesNotFailIt() async throws {
        let model = try await composer()
        defer { model.discard() }

        model.subject = "Lunch"
        _ = try await waitForRow(model, subject: "Lunch")
        // Keystrokes while the previous write may still be in flight.
        for subject in ["Lunch t", "Lunch to", "Lunch tomorrow"] {
            model.subject = subject
            try await Task.sleep(for: .milliseconds(420))
        }
        let row = try await waitForRow(model, subject: "Lunch tomorrow")
        #expect(row != nil)
        #expect(model.saveStatus != .failed(String(localized: "Error saving draft")))
    }

    /// The engine stamps the row (remoteId/savedAt) after the composer's last write; the
    /// composer's next write must keep the stamp, else the next flush creates a second
    /// server draft.
    @Test func aComposerWriteKeepsTheEnginesStamp() async throws {
        let model = try await composer()
        defer { model.discard() }

        model.subject = "Lunch"
        await model.writeNow()
        let id = try #require(model.draftId)
        try await store.setDraftSync(id: id, remoteId: 4_242, savedAt: 1, syncError: nil)

        model.subject = "Lunch tomorrow"
        await model.writeNow()

        let row = try #require(try await store.draft(id: id))
        #expect(row.subject == "Lunch tomorrow")
        #expect(row.remoteId == 4_242)
        #expect(row.savedAt == 1)
    }
}
