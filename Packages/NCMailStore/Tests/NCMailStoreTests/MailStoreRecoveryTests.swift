// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailStore

/// The recovery the app offers when the mirror will not open: delete it and start again.
@Suite("Mirror recovery")
struct MailStoreRecoveryTests {
    @Test("an unreadable mirror is refused, and after deleting it a fresh one opens in its place")
    func deleteThenReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ncmail-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "mirror.sqlite")
        try Data(repeating: 0x2A, count: 4096).write(to: url)

        #expect(throws: MailStoreError.self) { try MailStore(url: url) }

        try MailStore.deleteDatabase(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        _ = try MailStore(url: url)
    }

    @Test("deleting a mirror that is not there is not an error")
    func deleteMissing() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ncmail-absent-\(UUID().uuidString).sqlite")
        try MailStore.deleteDatabase(at: url)
    }
}
