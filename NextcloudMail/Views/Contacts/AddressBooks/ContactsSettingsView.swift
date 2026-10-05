// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// Web Contacts' settings that are not address books: the sort order and "Update avatars from
/// social media". Both are per-Mac `UserDefaults` values (ADR-0096).
struct ContactsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @AppStorage(ContactsSortOrder.storageKey) private var orderKey = ContactsSortOrder.default.rawValue
    @AppStorage(ContactsSocialAutoUpdate.storageKey) private var autoUpdate = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Contacts settings").font(.headline)
            Form {
                Picker("Sort contacts by", selection: $orderKey) {
                    ForEach(ContactsSortOrder.allCases) { order in
                        Text(order.title).tag(order.rawValue)
                    }
                }
                Toggle("Update avatars from social media", isOn: $autoUpdate)
                Text(
                    "When on, opening a contact asks the server for its picture from a social network it lists, at most once a day per contact."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 440)
    }
}

/// The social-avatar auto-update. Web Contacts' switch turns on a server-side background job
/// (`social/config/user/enableSocialSync`), a route this app has no client for; here the
/// switch is per Mac and does the same work on view: opening a contact in a writable book
/// queues a `contactSocialAvatar` for the first network the card supports, once per day per
/// card (ADR-0096).
enum ContactsSocialAutoUpdate {
    static let storageKey = "contacts.socialAutoUpdate"
    /// `[UID: seconds since 1970]` of the last request, so a card is asked about daily at most.
    static let requestedKey = "contacts.socialAutoUpdate.requested"
    nonisolated static let interval: TimeInterval = 24 * 60 * 60

    /// Whether `uid` is due, given the stored stamps; pure for the tests.
    nonisolated static func isDue(uid: String, stamps: [String: Double], now: Date) -> Bool {
        guard let last = stamps[uid] else { return true }
        return now.timeIntervalSince1970 - last >= interval
    }

    static func viewed(_ record: ContactRecord, model: ContactsLoginModel, browser: ContactsBrowser) async {
        guard let uid = record.uid, !uid.isEmpty, !record.isGroup,
            let book = model.book(id: record.addressBookId), !book.isReadOnly,
            let card = try? VCardParser.parse(record.vcard).first,
            let network = ContactsActions.socialNetworks(for: card).first
        else { return }
        let defaults = UserDefaults.standard
        var stamps = defaults.dictionary(forKey: requestedKey) as? [String: Double] ?? [:]
        let now = Date()
        guard isDue(uid: uid, stamps: stamps, now: now) else { return }
        // A short dwell, so arrowing down the list does not queue a request per row passed.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        stamps[uid] = now.timeIntervalSince1970
        defaults.set(stamps, forKey: requestedKey)
        // Nobody asked for this one, so a refusal (signed out) is not worth an alert.
        guard let actions = browser.actions(sessionId: model.sessionId) else { return }
        try? await actions.fetchSocialAvatar(network: network, contact: record, in: book)
    }
}
