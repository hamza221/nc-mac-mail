// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// What `⌘P` puts on paper, and when it is offered.
///
/// The print operation itself needs a window and a printer, so it is not here; the document
/// it loads is, because that is where attacker-controlled header text meets markup.
@Suite("Message printing")
@MainActor
struct MessagePrintTests {
    private static let server = "http://cloud.example.com"

    private static func header(
        subject: String? = "Quarterly report",
        sender: Address? = Address(label: "Lorelai Gilmore", email: "lorelai@example.com")
    ) -> MessageHeader {
        MessageHeader(
            messageId: 1,
            remoteId: 166,
            mailboxId: 1,
            threadRootId: nil,
            subject: subject,
            sender: sender,
            to: [Address(label: nil, email: "rory@example.com")],
            cc: [],
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isFlagged: false,
            isEncrypted: false
        )
    }

    private static func rendered(_ fragment: String) throws -> RenderedMessage {
        let policy = MessageRenderPolicy(
            server: try #require(URL(string: server)),
            messageRemoteId: 166,
            showsRemoteImages: false
        )
        return MessageHTMLRewriter(policy: policy).render(fragment: fragment, baseFontSize: 13)
    }

    private static func services() throws -> MessageViewServices {
        let url = try #require(URL(string: server))
        return MessageViewServices(
            store: try MailStore.inMemory(),
            client: MailClient(
                server: url,
                credentials: BasicCredentials(loginName: "lorelai", appPassword: "secret"),
                transport: ReplayTransport.answering(status: 200)
            ),
            server: url
        )
    }

    // MARK: - The document

    @Test("every header value is escaped, because every one is the sender's to choose")
    func headerValuesAreEscaped() {
        let message = PrintableMessage(
            header: Self.header(
                subject: "<script>steal()</script>",
                sender: Address(label: "<img src=x onerror=steal()>", email: "eve@example.com")
            ),
            body: .plain(text: "Hi", signature: nil)
        )

        let document = MessagePrintDocument.html(for: message)

        #expect(!document.contains("<script>"))
        #expect(!document.contains("<img src=x"))
        #expect(document.contains("&lt;script&gt;steal()&lt;/script&gt;"))
        #expect(document.contains("&lt;img src=x onerror=steal()&gt; &lt;eve@example.com&gt;"))
        #expect(document.contains("rory@example.com"))
    }

    @Test("a plain body prints escaped and wrapped, with its signature under a rule")
    func plainBodyIsEscapedInsideAPre() {
        let message = PrintableMessage(
            header: Self.header(),
            body: .plain(text: "a < b & </pre><b>c</b>", signature: "Lorelai")
        )

        let document = MessagePrintDocument.html(for: message)

        #expect(document.contains("a &lt; b &amp; &lt;/pre&gt;&lt;b&gt;c&lt;/b&gt;"))
        #expect(document.contains("white-space: pre-wrap"))
        #expect(document.contains("<hr>"))
        #expect(document.contains("Lorelai</pre>"))
        // The shell forces the light canvas on a plain body: paper is white.
        #expect(document.contains("<meta name=\"color-scheme\" content=\"light\">"))
    }

    @Test("an HTML body prints in its own rewritten document, with the header first inside it")
    func htmlBodyKeepsItsDocument() throws {
        let rendered = try Self.rendered("<p>Hello from the body</p>")
        let message = PrintableMessage(
            header: Self.header(),
            body: .html(rendered, .none)
        )

        let document = MessagePrintDocument.html(for: message)

        let open = try #require(document.range(of: MessageDocument.bodyOpenTag))
        let subject = try #require(document.range(of: "Quarterly report"))
        let body = try #require(document.range(of: "Hello from the body"))
        // Everything up to and including `<body>` is the document the screen shows, untouched.
        let shownOpen = try #require(rendered.document.range(of: MessageDocument.bodyOpenTag))
        #expect(document.hasPrefix(String(rendered.document[..<shownOpen.upperBound])))
        #expect(open.upperBound <= subject.lowerBound)
        #expect(subject.upperBound <= body.lowerBound)
    }

    // MARK: - When ⌘P is offered

    @Test("only a body that is drawn can be printed")
    func onlyDrawnBodiesArePrintable() throws {
        #expect(PrintableMessage.Body(.waiting) == nil)
        #expect(PrintableMessage.Body(.failed) == nil)
        #expect(PrintableMessage.Body(.blocked("no rule list")) == nil)
        #expect(PrintableMessage.Body(.plain(text: "Hi", signature: nil)) != nil)
        #expect(PrintableMessage.Body(.html(try Self.rendered("<p>Hi</p>"), .none)) != nil)
    }

    @Test("print follows the pane, and a pane that went away cannot clear its replacement")
    func registrationFollowsThePane() throws {
        let controller = MessagePrintController()
        let services = try Self.services()
        let first = NSObject()
        let second = NSObject()
        let message = PrintableMessage(header: Self.header(), body: .plain(text: "Hi", signature: nil))

        #expect(!controller.canPrint)
        controller.show(message, services: services, from: first)
        #expect(controller.canPrint)
        controller.show(nil, services: services, from: first)
        #expect(!controller.canPrint)

        // The rebuilt pane registers before the old one's `onDisappear` runs.
        controller.show(message, services: services, from: second)
        controller.withdraw(from: first)
        #expect(controller.canPrint)
        controller.withdraw(from: second)
        #expect(!controller.canPrint)
    }

    @Test("the menu item asks the pane, not just the list")
    func triageAsksWhetherThereIsSomethingToPrint() throws {
        let store = try MailStore.inMemory()
        let controller = MessagePrintController()
        let context = TriageContext(store: store)
        context.printMessage = {}
        context.canPrintMessage = { controller.canPrint }

        #expect(!context.isEnabled(.printMessage))
        controller.show(
            PrintableMessage(header: Self.header(), body: .plain(text: "Hi", signature: nil)),
            services: try Self.services(),
            from: context
        )
        #expect(context.isEnabled(.printMessage))
    }
}
