// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import SwiftUI

/// Why there is no picture for an address.
///
/// `NCAvatar` draws coloured initials when its loader throws, so "nothing stored" and "the
/// server said 404" need no special case at the call site — but they are different facts and
/// whatever ends up fetching avatars has to tell them apart.
enum AvatarUnavailable: Error {
    /// Nothing has been recorded for this address yet.
    case notStored
    /// The server answered 404 and the mirror remembered it, so nobody asks again.
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
    /// this is ours. It makes no request: the network writes the database and views read it,
    /// which is the invariant in
    /// [overview.md](../../../docs/architecture/overview.md#the-invariant). Nothing writes
    /// the `avatar` table yet, so in practice every address still draws initials — what has
    /// changed is that it draws them because the row is absent rather than because there was
    /// no way to look.
    ///
    /// - Returns: nil for an address that cannot be looked up at all, which is what the
    ///   components take to mean "do not try".
    func avatarLoader(for email: String?) -> (@Sendable () async throws -> Image)? {
        guard let email, !email.isEmpty else { return nil }
        return { [self] in
            guard let record = try await avatar(for: email) else { throw AvatarUnavailable.notStored }
            guard !record.missing else { throw AvatarUnavailable.noneOnTheServer }
            guard let data = record.data, let image = NSImage(data: data) else {
                throw AvatarUnavailable.undecodable
            }
            return Image(nsImage: image)
        }
    }
}
