// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

/// Every way a message gets started, as one value a composer window is opened for.
///
/// The cases are the roadmap's, verbatim (WS-25 brief), so WS-27's composer, WS-29/31's
/// reply and forward actions and WS-42's `mailto:` and Share extension agree on one shape.
/// `nonisolated` because the app target defaults to `@MainActor` and `openWindow(id:value:)`
/// encodes the value off the main actor for scene restoration.
nonisolated enum ComposeRequest: Codable, Hashable, Sendable {
    case new(accountId: Int64?, mailto: URL?)
    case reply(messageId: Int64, mode: ReplyMode)  // ReplyMode: .sender, .all, .followUp
    case forward(messageIds: [Int64], asAttachment: Bool)
    case editAsNew(messageId: Int64)
    case draft(draftId: Int64)
    case outbox(outboxId: Int64)
    case smartReply(messageId: Int64, text: String)
    case shared(inboxItemId: String)  // Share extension hand-off
}

/// Who a reply goes to. `.followUp` is the web client's "Follow up" on a message the user
/// sent and nobody answered: a reply to the original recipients.
nonisolated enum ReplyMode: String, Codable, Hashable, Sendable {
    case sender
    case all
    case followUp
}

/// `@Environment(\.openComposer)`: opens one composer window for a request.
///
/// The scene it opens, `WindowGroup(id: "composer", for: ComposeRequest.self)`, is WS-27's.
/// Until it is registered, calling this opens nothing and SwiftUI logs that no scene matches
/// — the action exists now so every caller can be written against it.
struct OpenComposerAction {
    static let windowId = "composer"

    fileprivate let openWindow: OpenWindowAction

    func callAsFunction(_ request: ComposeRequest) {
        openWindow(id: Self.windowId, value: request)
    }
}

extension EnvironmentValues {
    /// Derived from `openWindow` rather than injected, so it is available in every window,
    /// Settings included, with nothing to set up.
    var openComposer: OpenComposerAction {
        OpenComposerAction(openWindow: openWindow)
    }
}
