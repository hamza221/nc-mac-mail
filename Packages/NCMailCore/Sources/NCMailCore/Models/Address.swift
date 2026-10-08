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

    /// The address to show beside ``displayName``, or nil when ``displayName`` already is
    /// the address.
    ///
    /// The label is the sender's to choose, so on its own it identifies nobody:
    /// `"security@paypal.com" <attacker@evil.example>` has a label that reads as an address
    /// and is not this one. Whenever the label is not the address, the address has to be on
    /// screen too, and whenever it is, showing both would just say it twice. The comparison
    /// ignores case and surrounding blanks because neither makes the label a different
    /// mailbox to the reader.
    public var addressBesideName: String? {
        guard let email, !email.isEmpty, let label, !label.isEmpty else { return nil }
        let shown = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return shown.caseInsensitiveCompare(email) == .orderedSame ? nil : email
    }

    /// `Name <address>` when the two differ, otherwise the one of them there is. For the
    /// places with room for a single string that still must not hide the address: a tooltip,
    /// a VoiceOver label, a printed header.
    public var nameAndAddress: String {
        guard let address = addressBesideName else { return displayName }
        return "\(displayName) <\(address)>"
    }
}
