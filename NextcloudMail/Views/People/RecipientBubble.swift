// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// A person in a message header (§5.11): avatar and name, and a click opens the contact card.
///
/// The name is the header's label for the address, else the address itself — the bubble does
/// not look the contact up, so a list of thirty recipients costs thirty views and no queries;
/// the card does the lookup when it opens.
struct RecipientBubble: View {
    let email: String
    let label: String?
    let accountId: Int64?

    @Environment(AppSession.self) private var session
    @State private var isShowingCard = false

    init(email: String, label: String? = nil, accountId: Int64? = nil) {
        self.email = email
        self.label = label
        self.accountId = accountId
    }

    private var displayName: String {
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return email }
        return label
    }

    var body: some View {
        NCUserBubble(
            displayName: displayName,
            user: email,
            load: session.store.avatarLoader(for: email),
            action: { isShowingCard = true }
        )
        .help(email)
        .accessibilityHint(Text("Shows the contact card"))
        .popover(isPresented: $isShowingCard, arrowEdge: .bottom) {
            ContactCardPopover(email: email, label: label, accountId: accountId)
        }
    }
}
