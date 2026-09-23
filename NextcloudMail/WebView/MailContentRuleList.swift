// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import OSLog
import WebKit

/// The third layer: a rule list that blocks every load a message can ask for except our own
/// scheme.
///
/// JavaScript is off and the server already neutralised remote images, so this is not the
/// control that stops the common case — it is the one that holds when the other two are
/// wrong. One sanitiser bug should not become an outbound request
/// ([security.md](../../docs/architecture/security.md)).
@MainActor
enum MailContentRuleList {
    /// Bumped when ``json`` changes, because the store keys compiled lists by identifier and
    /// a stale compilation would otherwise outlive the rule it came from.
    static let identifier = "ncmail.block-everything-but-ncmail.1"

    /// Block everything, then take the block back for `ncmail:`.
    ///
    /// Order is the semantics: rules apply in sequence and `ignore-previous-rules` undoes
    /// what came before it, so the exception must be second. Written out rather than encoded
    /// from a model because it is a security control, and a reviewer should be able to read
    /// the whole of it without running anything.
    static let json = """
        [
          {
            "trigger": { "url-filter": ".*" },
            "action": { "type": "block" }
          },
          {
            "trigger": { "url-filter": "^ncmail://asset/", "url-filter-is-case-sensitive": false },
            "action": { "type": "ignore-previous-rules" }
          }
        ]
        """

    private static var compilation: Task<WKContentRuleList, any Error>?

    /// The compiled list, compiled once per launch and shared by every message view.
    ///
    /// Compilation is a WebKit round trip measured in tens of milliseconds; doing it per
    /// message would put it on the path between clicking a message and seeing it.
    static func compiled() async throws -> WKContentRuleList {
        if let compilation { return try await compilation.value }
        let task = Task<WKContentRuleList, any Error> {
            guard let store = WKContentRuleListStore.default() else {
                throw MailContentRuleListError.noStore
            }
            guard
                let list = try await store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: json
                )
            else {
                throw MailContentRuleListError.compilationReturnedNothing
            }
            return list
        }
        compilation = task
        do {
            return try await task.value
        } catch {
            // A failed compilation is not cached: the view fails closed and shows an error,
            // and the next message tries again rather than inheriting the failure forever.
            compilation = nil
            throw error
        }
    }
}

nonisolated enum MailContentRuleListError: Error, CustomStringConvertible {
    case noStore
    case compilationReturnedNothing

    var description: String {
        switch self {
        case .noStore: "WebKit has no content rule list store"
        case .compilationReturnedNothing: "the content rule list compiled to nothing"
        }
    }
}

/// A name for a failure that is safe to log or to show.
///
/// The render path is the one place where an error object can carry mail. `URLError`
/// prints the URL it failed on, and on the image path that URL *is* message content — a
/// tracker's address with the recipient's id in it. GRDB's `DatabaseError` prints the SQL
/// and its arguments, which on this path includes an attachment. So nothing here
/// interpolates an error: it interpolates a name.
nonisolated enum RenderFailure {
    static func label(_ error: any Error) -> String {
        if let mail = error as? MailError { return mail.description }
        if let asset = error as? MailAssetError { return asset.description }
        if let rules = error as? MailContentRuleListError { return rules.description }
        // The type name, and nothing the type was carrying.
        return String(describing: type(of: error))
    }
}

/// One logger for the rendering path. Nothing here ever interpolates a URL, a subject, an
/// address or a body: rule names, counts and refusal reasons are the whole vocabulary.
nonisolated let renderLog = Logger(subsystem: "com.nextcloud.mail.macos", category: "render")
