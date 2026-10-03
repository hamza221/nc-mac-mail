// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import SwiftUI

/// Why there is no picture for an address.
///
/// `NCAvatar` draws coloured initials when its loader throws, so "the server said 404" and
/// "the bytes are junk" need no special case at the call site — but they are different
/// facts, and the log is clearer for keeping them apart.
enum AvatarUnavailable: Error {
    /// The server answered 404 and the mirror remembered it.
    case noneOnTheServer
    /// Bytes are there and are not an image this machine can decode.
    case undecodable
}

extension MailStore {
    /// An avatar loader for `NCAvatar` and `NCUserBubble`, reading the mirror and nothing
    /// else.
    ///
    /// The library forbids `AsyncImage` and takes a loader instead
    /// ([ui-components.md](../../../docs/reference/ui-components.md#avatar-loading)), and
    /// this is ours. It makes no request: `AvatarFetcher` writes the `avatar` table and this
    /// *waits on the row*, which is the invariant in
    /// [overview.md](../../../docs/architecture/overview.md#the-invariant). Until the row
    /// exists, `NCAsyncImage` shows initials. When the fetcher writes it, the observation
    /// fires and the photo replaces them in place, with no reload and no second view.
    /// Scrolling the row away cancels the wait.
    ///
    /// - Returns: nil for an address that cannot be looked up at all, which is what the
    ///   components take to mean "do not try".
    func avatarLoader(for email: String?) -> (@Sendable () async throws -> Image)? {
        guard let email, !email.isEmpty else { return nil }
        return { [self] in
            for try await record in observeAvatar(for: email) {
                guard let record else { continue }
                guard !record.missing else { throw AvatarUnavailable.noneOnTheServer }
                guard let data = record.data, let image = NSImage(data: data) else {
                    throw AvatarUnavailable.undecodable
                }
                return Image(nsImage: image)
            }
            throw CancellationError()
        }
    }
}
