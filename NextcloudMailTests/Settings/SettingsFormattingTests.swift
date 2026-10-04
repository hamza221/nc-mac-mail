// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// Pure logic, no database and no network: what `mirrorStatus` says for each state, and the
/// `MarkAsReadDelay` encoding a meta value round-trips through.
@Suite("SettingsFormatting")
struct SettingsFormattingTests {
    @Test("a nil last sync reads as never, deterministically")
    func neverSynced() {
        #expect(SettingsFormatting.lastSync(nil) == "Never")
    }

    @Test("a real last sync reads as something other than never")
    func realSync() {
        let text = SettingsFormatting.lastSync(1_700_000_000)
        #expect(!text.isEmpty)
        #expect(text != "Never")
    }

    @Test("idle reads as not started")
    func idle() {
        #expect(SettingsFormatting.mirrorStatus(state: .idle, progress: nil, isPaused: false) == "Not started")
    }

    @Test("envelopes with mailboxes left names the count")
    func envelopesInProgress() {
        let progress = MirrorProgress(totalMessages: 10, bodiesPresent: 0, bodiesFailed: 0, mailboxesRemaining: 3)
        let text = SettingsFormatting.mirrorStatus(state: .envelopes, progress: progress, isPaused: false)
        #expect(text.contains("3"))
    }

    @Test("bodies in progress names how many remain")
    func bodiesInProgress() {
        let progress = MirrorProgress(totalMessages: 100, bodiesPresent: 40, bodiesFailed: 0, mailboxesRemaining: 0)
        let text = SettingsFormatting.mirrorStatus(state: .bodies, progress: progress, isPaused: false)
        #expect(text.contains("60"))
    }

    @Test("bodies in progress mentions a non-zero failure count")
    func bodiesWithFailures() {
        let progress = MirrorProgress(totalMessages: 100, bodiesPresent: 40, bodiesFailed: 5, mailboxesRemaining: 0)
        let text = SettingsFormatting.mirrorStatus(state: .bodies, progress: progress, isPaused: false)
        #expect(text.contains("55"))
        #expect(text.contains("5"))
    }

    @Test("complete reads as complete regardless of a stale progress row")
    func complete() {
        #expect(SettingsFormatting.mirrorStatus(state: .complete, progress: nil, isPaused: false) == "Mirror complete")
    }

    @Test("paused overrides every other state, and names what is left")
    func pausedMidBackfill() {
        let progress = MirrorProgress(totalMessages: 100, bodiesPresent: 40, bodiesFailed: 0, mailboxesRemaining: 0)
        let text = SettingsFormatting.mirrorStatus(state: .bodies, progress: progress, isPaused: true)
        #expect(text.contains("40"))
        #expect(text.contains("100"))
    }

    @Test("paused with nothing left to do just says paused")
    func pausedComplete() {
        let progress = MirrorProgress(totalMessages: 10, bodiesPresent: 10, bodiesFailed: 0, mailboxesRemaining: 0)
        #expect(SettingsFormatting.mirrorStatus(state: .complete, progress: progress, isPaused: true) == "Paused")
    }

    @Test("every server mark-as-read choice round-trips through the local meta encoding")
    func markAsReadRoundTrip() {
        for value in AutoMarkAsRead.allCases {
            #expect(MarkAsReadDelay(metaValue: value.localDelay.metaValue) == value.localDelay)
        }
    }

    @Test("a nil or unrecognised meta value falls back to immediately")
    func markAsReadFallback() {
        #expect(MarkAsReadDelay(metaValue: nil) == .immediately)
        #expect(MarkAsReadDelay(metaValue: "nonsense") == .immediately)
        #expect(MarkAsReadDelay(metaValue: "after:not-a-number") == .immediately)
    }
}
