// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreSpotlight
import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

@Suite("System links: parsing")
struct SystemLinkTests {
    @Test func mailtoIsACompose() throws {
        let url = try #require(URL(string: "mailto:x@y.z?subject=Hi"))
        #expect(SystemLink(url: url) == .compose(mailto: url))
        let upper = try #require(URL(string: "MAILTO:x@y.z"))
        #expect(SystemLink(url: upper) == .compose(mailto: upper))
    }

    /// WS-30's "Copy direct link" builds the URL; this is the receiving end of the same format.
    @Test func directLinksRoundTripWithTheCopiedFormat() throws {
        for header in ["<user@example.com>", "<a/b?c#d@x>", "<ünï cødé+tag@example.com>"] {
            let url = try #require(MessageDirectLink.url(messageIdHeader: header))
            #expect(SystemLink(url: url) == .openMessageId(header))
            #expect(SystemLink.openMessageId(header).url == url)
        }
    }

    @Test func appLinks() throws {
        #expect(SystemLink(url: try #require(URL(string: "ncmail://message/42"))) == .message(42))
        #expect(SystemLink(url: try #require(URL(string: "ncmail://contact/7"))) == .contact(7))
        let itemId = UUID().uuidString
        #expect(SystemLink(url: try #require(URL(string: "ncmail://shared/\(itemId)"))) == .shared(inboxItemId: itemId))
        for link in [SystemLink.message(42), .contact(7), .shared(inboxItemId: itemId)] {
            #expect(link.url.flatMap(SystemLink.init(url:)) == link)
        }
    }

    @Test func everythingElseIsNotALink() throws {
        for text in [
            "ncmail://asset/aHR0cDovL2E", "ncmail://open/", "ncmail://open", "ncmail://message/abc",
            "ncmail://message/1/2", "ncmail://shared/%2E%2E", "ncmail://shared/a%2Fb", "ncmail://other/1",
            "https://example.com/open/x", "ncmail:open",
        ] {
            let url = try #require(URL(string: text), "\(text)")
            #expect(SystemLink(url: url) == nil, "\(text)")
        }
    }

    /// A Services selection with every character a query could split on lands whole.
    @Test func aSelectionBecomesTheBodyIntact() throws {
        let text = "a & b = c + d?\nline two #hash 100% ünï"
        let link = try #require(SystemLink.compose(body: text))
        guard case .compose(let mailto) = link else {
            Issue.record("not a compose")
            return
        }
        let fields = try #require(MailtoFields(url: mailto))
        #expect(fields.body == text)
        #expect(fields.to.isEmpty)
        #expect(fields.subject == nil)
    }

    @Test func spotlightIdentifiersRouteBack() {
        #expect(SpotlightIdentifier.link(for: SpotlightIdentifier.make(.message, 12)) == .message(12))
        #expect(SpotlightIdentifier.link(for: SpotlightIdentifier.make(.contact, 3)) == .contact(3))
        #expect(SpotlightIdentifier.link(for: "message:x") == nil)
        #expect(SpotlightIdentifier.link(for: "calendar:1") == nil)
    }

    @Test @MainActor func aSpotlightContinuationIsALink() {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: "message:99"]
        #expect(SystemAppDelegate.link(for: activity) == .message(99))
        #expect(SystemAppDelegate.link(for: NSUserActivity(activityType: "other")) == nil)
    }
}

@Suite("System links: AppKit doors")
@MainActor
struct SystemDoorTests {
    @Test func servicesSelectionPostsACompose() throws {
        var posted: [SystemLink] = []
        let provider = SystemServicesProvider(post: { posted.append($0) })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ws42-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Meeting notes", forType: .string)
        var error: NSString?
        provider.newMessageWithSelection(pasteboard, userData: nil, error: &error)
        #expect(error == nil)
        guard case .compose(let mailto) = try #require(posted.first) else {
            Issue.record("not a compose")
            return
        }
        #expect(MailtoFields(url: mailto)?.body == "Meeting notes")
    }

    @Test func emptySelectionIsAnError() {
        var posted: [SystemLink] = []
        let provider = SystemServicesProvider(post: { posted.append($0) })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ws42-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        var error: NSString?
        provider.newMessageWithSelection(pasteboard, userData: nil, error: &error)
        #expect(error != nil)
        #expect(posted.isEmpty)
    }

    /// The Info.plist's `NSMessage` names a method the provider answers.
    @Test func infoPlistDeclaresTheSchemesAndTheService() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] })
        #expect(schemes == ["mailto", "ncmail"])
        let services = try #require(info["NSServices"] as? [[String: Any]])
        let message = try #require(services.first?["NSMessage"] as? String)
        #expect(SystemServicesProvider().responds(to: NSSelectorFromString("\(message):userData:error:")))
        let menu = services.first?["NSMenuItem"] as? [String: String]
        #expect(menu?["default"] == "New Nextcloud Mail message with selection")
    }

    @Test func eventsWaitForTheirHandler() {
        let events = SystemEvents()
        events.post(.message(1))
        events.post(.contact(2))
        var seen: [SystemLink] = []
        events.setHandler { seen.append($0) }
        events.post(.message(3))
        #expect(seen == [.message(1), .contact(2), .message(3)])
    }
}

@Suite("System links: routing")
@MainActor
struct SystemRouterTests {
    private struct Harness {
        var fixture: SystemFixture
        let navigation: NavigationState
        let list: MessageListStore
        let contacts: ContactsBrowser
        let router: SystemRouter
        let composed: Box<[ComposeRequest]>
        let windows: Box<[Int64]>
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func harness(attached: Bool = true) async throws -> Harness {
        let fixture = try await SystemFixture.make()
        let navigation = NavigationState(store: fixture.store)
        let composed = Box<[ComposeRequest]>([])
        let windows = Box<[Int64]>([])
        let router = SystemRouter(
            store: fixture.store, navigation: navigation, openComposer: { composed.value.append($0) },
            openMessageWindow: { windows.value.append($0) }, settle: .milliseconds(50))
        let list = MessageListStore(store: fixture.store)
        let contacts = ContactsBrowser(store: fixture.store, queue: { _ in nil })
        if attached {
            router.messageList = list
            router.contacts = contacts
        }
        return Harness(
            fixture: fixture, navigation: navigation, list: list, contacts: contacts, router: router,
            composed: composed, windows: windows)
    }

    @Test func mailtoOpensANewMessage() async throws {
        let harness = try await harness()
        let url = try #require(URL(string: "mailto:x@y.z?subject=Hi"))
        let outcome = await harness.router.handle(.compose(mailto: url))
        #expect(outcome == .composer(.new(accountId: nil, mailto: url)))
        #expect(harness.composed.value == [.new(accountId: nil, mailto: url)])
    }

    @Test func aSharedItemOpensTheSharedRequest() async throws {
        let harness = try await harness()
        await harness.router.handle(.shared(inboxItemId: "abc"))
        #expect(harness.composed.value == [.shared(inboxItemId: "abc")])
    }

    /// `ncmail://open/<Message-ID>`: the mailbox in the sidebar, the row in the list.
    @Test func aDirectLinkSelectsTheMessage() async throws {
        var harness = try await harness()
        let id = try await harness.fixture.message(
            remoteId: 1, mailboxId: harness.fixture.archiveId, header: "<deep@example.invalid>")
        let url = try #require(MessageDirectLink.url(messageIdHeader: "<deep@example.invalid>"))
        let link = try #require(SystemLink(url: url))

        let outcome = await harness.router.handle(link)

        #expect(outcome == .message(id))
        #expect(harness.navigation.selection == .mailbox(harness.fixture.archiveId))
        #expect(harness.list.selection == [id])
        #expect(harness.list.focusedMessageId == id)
        #expect(harness.windows.value.isEmpty)
    }

    @Test func aLinkToNothingSelectsNothing() async throws {
        let harness = try await harness()
        #expect(await harness.router.handle(.openMessageId("<missing@example.invalid>")) == .notFound)
        #expect(await harness.router.handle(.message(9_999)) == .notFound)
        #expect(await harness.router.handle(.contact(9_999)) == .notFound)
        #expect(harness.navigation.selection == nil)
    }

    /// With no main window to select in, the message opens in its own window.
    @Test func withoutAWindowTheMessageGetsItsOwn() async throws {
        var harness = try await harness(attached: false)
        let id = try await harness.fixture.message(remoteId: 2, header: "<w@example.invalid>")
        #expect(await harness.router.handle(.message(id)) == .message(id))
        #expect(harness.windows.value == [id])
    }

    /// A Spotlight contact: its address book in the login's Contacts section, then the card.
    @Test func aContactResultSelectsTheCard() async throws {
        let harness = try await harness()
        let ada = try #require(harness.fixture.contacts["Ada Lovelace"])
        #expect(await harness.router.handle(.contact(ada)) == .contact(ada))
        let sessionId = AccountSession.identifier(
            server: SystemFixture.identity.serverURL, loginName: SystemFixture.identity.loginName)
        #expect(
            harness.navigation.selection
                == .contacts(sessionId: sessionId, scope: .addressBook(harness.fixture.bookId)))
        #expect(harness.contacts.selection == [ada])
    }
}
