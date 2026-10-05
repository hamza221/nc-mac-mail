// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog
import UserNotifications

/// One banner the app asks for, in the app's own terms rather than `UNNotificationContent`'s,
/// so a test can assert on it without a notification center behind it.
nonisolated struct MailNotificationRequest: Sendable, Equatable {
    /// The categories registered with the system. The actions a banner shows follow from it.
    enum Category: String, Sendable, CaseIterable {
        /// A new message: Archive, Mark as read, Reply.
        case message = "mail.message"
        /// A new message of an account with no archive mailbox: Mark as read, Reply. Offering
        /// Archive there would be a button that does nothing.
        case messageWithoutArchive = "mail.message.noArchive"
        /// "N new messages" when one sync pass brought more than ``MailNotifier/individualLimit``.
        case summary = "mail.summary"
        /// A Nextcloud notification of the Mail app (quota, delegation).
        case server = "mail.server"
    }

    var identifier: String
    /// The sender for a message; the server's subject line for a Nextcloud notification.
    var title: String
    /// The subject for a message. The system hides it, with the title, when the user turned
    /// "Show previews" off for the app — which is why nothing private goes anywhere else.
    var body: String
    /// Banners of one thread stack together (`account|threadRootId`).
    var threadIdentifier: String
    var category: Category
    var messageId: Int64?
    var accountId: Int64?
    /// The inbox, for a summary banner: clicking it selects that inbox.
    var mailboxId: Int64?
    /// Where clicking a Nextcloud notification goes.
    var link: URL?
}

/// What the user did with a banner.
nonisolated struct MailNotificationResponse: Sendable, Equatable {
    enum Action: String, Sendable {
        /// Clicked the banner itself.
        case open
        case archive
        case markRead
        case reply
    }

    var action: Action
    var messageId: Int64?
    var accountId: Int64?
    var mailboxId: Int64?
    var link: URL?
}

/// The notification center as ``MailNotifier`` uses it.
///
/// A protocol because `UNUserNotificationCenter` is unusable from an unsigned test runner (it
/// refuses authorization and every request), so the unit tests post into a fake that records
/// what would have been shown.
@MainActor
protocol MailNotificationCenter: AnyObject {
    /// Registers the categories, becomes the center's delegate, and asks for permission once.
    /// Responses arrive through `onResponse`.
    func activate(onResponse: @escaping @Sendable (MailNotificationResponse) async -> Void)
    func add(_ request: MailNotificationRequest) async
    func removeDelivered(identifiers: [String])
}

/// `UNUserNotificationCenter`, behind ``MailNotificationCenter``.
@MainActor
final class SystemNotificationCenter: MailNotificationCenter {
    private var delegate: Delegate?
    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "notifications")

    private nonisolated enum UserInfoKey {
        static let messageId = "messageId"
        static let accountId = "accountId"
        static let mailboxId = "mailboxId"
        static let link = "link"
    }

    private nonisolated enum ActionId {
        static let archive = "mail.archive"
        static let markRead = "mail.markRead"
        static let reply = "mail.reply"
    }

    func activate(onResponse: @escaping @Sendable (MailNotificationResponse) async -> Void) {
        let center = UNUserNotificationCenter.current()
        let delegate = Delegate(onResponse: onResponse)
        self.delegate = delegate
        center.delegate = delegate
        center.setNotificationCategories(Self.categories())
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Self.logger.info("notification authorization: \(granted, privacy: .public)")
            } catch {
                // An unsigned build is refused here; the app carries on without banners.
                Self.logger.error("notification authorization failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func add(_ request: MailNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.categoryIdentifier = request.category.rawValue
        content.sound = .default
        var info: [String: Any] = [:]
        if let messageId = request.messageId { info[UserInfoKey.messageId] = NSNumber(value: messageId) }
        if let accountId = request.accountId { info[UserInfoKey.accountId] = NSNumber(value: accountId) }
        if let mailboxId = request.mailboxId { info[UserInfoKey.mailboxId] = NSNumber(value: mailboxId) }
        if let link = request.link { info[UserInfoKey.link] = link.absoluteString }
        content.userInfo = info
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
        } catch {
            Self.logger.error("notification not added: \(String(describing: error), privacy: .public)")
        }
    }

    func removeDelivered(identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// With "Show previews" off the system shows the placeholder instead of title and body;
    /// `hiddenPreviewsShowTitle` is deliberately not set, because the title is the sender.
    private static func categories() -> Set<UNNotificationCategory> {
        let archive = UNNotificationAction(
            identifier: ActionId.archive, title: String(localized: "Archive"), options: [])
        let markRead = UNNotificationAction(
            identifier: ActionId.markRead, title: String(localized: "Mark as read"), options: [])
        let reply = UNNotificationAction(
            identifier: ActionId.reply, title: String(localized: "Reply"), options: [.foreground])
        let placeholder = String(localized: "New message")
        func category(
            _ id: MailNotificationRequest.Category, _ actions: [UNNotificationAction]
        ) -> UNNotificationCategory {
            UNNotificationCategory(
                identifier: id.rawValue,
                actions: actions,
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: placeholder,
                options: []
            )
        }
        return [
            category(.message, [archive, markRead, reply]),
            category(.messageWithoutArchive, [markRead, reply]),
            category(.summary, []),
            category(.server, []),
        ]
    }

    /// Reads the response into a value on whatever queue the system calls back on, then
    /// hands that value over: `UNNotificationResponse` itself never leaves this method.
    nonisolated static func response(
        actionIdentifier: String, userInfo: [AnyHashable: Any]
    ) -> MailNotificationResponse? {
        let action: MailNotificationResponse.Action
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .open
        case ActionId.archive: action = .archive
        case ActionId.markRead: action = .markRead
        case ActionId.reply: action = .reply
        default: return nil
        }
        return MailNotificationResponse(
            action: action,
            messageId: (userInfo[UserInfoKey.messageId] as? NSNumber)?.int64Value,
            accountId: (userInfo[UserInfoKey.accountId] as? NSNumber)?.int64Value,
            mailboxId: (userInfo[UserInfoKey.mailboxId] as? NSNumber)?.int64Value,
            link: (userInfo[UserInfoKey.link] as? String).flatMap(URL.init(string:))
        )
    }

    private nonisolated final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        let onResponse: @Sendable (MailNotificationResponse) async -> Void

        init(onResponse: @escaping @Sendable (MailNotificationResponse) async -> Void) {
            self.onResponse = onResponse
        }

        /// Frontmost or not, a banner that was asked for is shown: the suppression rule
        /// ("main window key and showing that mailbox") is applied before the request is made.
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            guard
                let value = SystemNotificationCenter.response(
                    actionIdentifier: response.actionIdentifier,
                    userInfo: response.notification.request.content.userInfo)
            else { return }
            await onResponse(value)
        }
    }
}
