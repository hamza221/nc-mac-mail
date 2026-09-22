// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One entry of a `from`, `to`, `cc`, `bcc` or `replyTo` list.
///
/// `email` is optional because a group address (`undisclosed-recipients:;`)
/// serialises with a label and no address.
public struct Address: Decodable, Sendable, Hashable {
    public let label: String?
    public let email: String?

    public init(label: String?, email: String?) {
        self.label = label
        self.email = email
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case email
    }

    /// What to show when there is room for one line: the label, falling back to
    /// the address, falling back to nothing rather than an empty box.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return email ?? ""
    }
}
