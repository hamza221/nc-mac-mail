// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

@testable import NCMailCore

/// Every rule in the brief, as its own test: `MailboxTree.build(from:)` is pure and
/// synchronous, so nothing here needs a database, a fixture bundle or an `async` test.
///
/// No force unwrap anywhere, including here (ADR-0028): every optional this suite needs to
/// unwrap goes through `try #require(...)`.
@Suite("MailboxTree")
struct MailboxTreeTests {
    private func row(
        id: Int64,
        name: String,
        delimiter: String? = ".",
        specialRole: String? = nil,
        isSelectable: Bool = true,
        isSubscribed: Bool = true,
        unreadCount: Int = 0
    ) -> MailboxTreeRow {
        MailboxTreeRow(
            id: id,
            name: name,
            delimiter: delimiter,
            specialRole: specialRole,
            isSelectable: isSelectable,
            isSubscribed: isSubscribed,
            unreadCount: unreadCount
        )
    }

    // MARK: - Leaf name

    @Test("the display name is the last path component, not the server's displayName")
    func leafNameIsLastComponent() throws {
        let nodes = MailboxTree.build(from: [row(id: 1, name: "INBOX.Work.Archive")])
        let inbox = try #require(nodes.first)
        #expect(inbox.displayName == "INBOX")
        let work = try #require(inbox.children.first)
        #expect(work.displayName == "Work")
        let archive = try #require(work.children.first)
        #expect(archive.displayName == "Archive")
        #expect(archive.row?.id == 1)
    }

    @Test("a nil delimiter is a flat namespace: the name is never split")
    func nilDelimiterIsFlat() throws {
        let nodes = MailboxTree.build(from: [row(id: 1, name: "INBOX.Work.Archive", delimiter: nil)])
        let node = try #require(nodes.first)
        #expect(nodes.count == 1)
        #expect(node.displayName == "INBOX.Work.Archive")
        #expect(node.children.isEmpty)
    }

    @Test("an empty delimiter is a flat namespace too")
    func emptyDelimiterIsFlat() throws {
        let nodes = MailboxTree.build(from: [row(id: 1, name: "INBOX.Work", delimiter: "")])
        let node = try #require(nodes.first)
        #expect(nodes.count == 1)
        #expect(node.displayName == "INBOX.Work")
    }

    @Test("unicode and modified UTF-7 names split cleanly on their delimiter")
    func unicodeAndModifiedUTF7Names() throws {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "Postfächer", delimiter: "/"),
            row(id: 2, name: "Postfächer/Persönlich", delimiter: "/"),
            row(id: 3, name: "&AKA-.&AKA-", delimiter: "."),
        ])
        let postfach = try #require(nodes.first { $0.displayName == "Postfächer" })
        #expect(postfach.children.map(\.displayName) == ["Persönlich"])

        // "&AKA-" is modified UTF-7 for U+2603; the literal "." inside it never occurs here,
        // so the split is unaffected by what the encoded run means. Only the two-level name
        // was given, so the top "&AKA-" is a synthetic container and its child is the real row.
        let encodedParent = try #require(nodes.first { $0.displayName == "&AKA-" && $0.row == nil })
        let encodedLeaf = try #require(encodedParent.children.first)
        #expect(encodedLeaf.displayName == "&AKA-")
        #expect(encodedLeaf.row?.id == 3)
    }

    // MARK: - Ordering

    @Test("special roles sort first, in the fixed order, ahead of everything alphabetical")
    func specialRolesSortFirst() {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "Zeta", delimiter: "/"),
            row(id: 2, name: "Alpha", delimiter: "/"),
            row(id: 3, name: "Trash", delimiter: "/", specialRole: "trash"),
            row(id: 4, name: "Sent", delimiter: "/", specialRole: "sent"),
            row(id: 5, name: "Junk", delimiter: "/", specialRole: "junk"),
            row(id: 6, name: "Inbox", delimiter: "/", specialRole: "inbox"),
            row(id: 7, name: "Drafts", delimiter: "/", specialRole: "drafts"),
            row(id: 8, name: "Archive", delimiter: "/", specialRole: "archive"),
        ])
        #expect(
            nodes.map(\.displayName) == [
                "Inbox", "Drafts", "Sent", "Archive", "Junk", "Trash", "Alpha", "Zeta",
            ])
    }

    @Test("the alphabetical rest sorts case- and locale-insensitively")
    func alphabeticalRestIsCaseInsensitive() {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "banana", delimiter: "/"),
            row(id: 2, name: "Apple", delimiter: "/"),
            row(id: 3, name: "cherry", delimiter: "/"),
        ])
        #expect(nodes.map(\.displayName) == ["Apple", "banana", "cherry"])
    }

    @Test("a special role of an unmodelled kind sorts with the alphabetical rest, not first")
    func unknownSpecialRoleIsNotSpecial() {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "Inbox", delimiter: "/", specialRole: "inbox"),
            row(id: 2, name: "Snoozed", delimiter: "/", specialRole: "snoozed"),
            row(id: 3, name: "Alpha", delimiter: "/"),
        ])
        #expect(nodes.map(\.displayName) == ["Inbox", "Alpha", "Snoozed"])
    }

    @Test("special-role comparison folds case, matching how the server sends it")
    func specialRoleComparisonFoldsCase() {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "Zeta", delimiter: "/"),
            row(id: 2, name: "Inbox", delimiter: "/", specialRole: "INBOX"),
        ])
        #expect(nodes.map(\.displayName) == ["Inbox", "Zeta"])
    }

    // MARK: - Synthetic containers

    @Test("a child whose parent has no row of its own gets a synthetic container")
    func syntheticContainerForMissingParent() throws {
        // Only the leaf exists; "Work" never appears as its own row.
        let nodes = MailboxTree.build(from: [row(id: 1, name: "INBOX.Work.Projects")])
        let inbox = try #require(nodes.first)
        #expect(inbox.row == nil)
        #expect(inbox.isSelectable == false)
        #expect(inbox.unreadCount == 0)

        let work = try #require(inbox.children.first)
        #expect(work.displayName == "Work")
        #expect(work.row == nil)
        #expect(work.isSelectable == false)

        let projects = try #require(work.children.first)
        #expect(projects.displayName == "Projects")
        #expect(projects.row?.id == 1)
        #expect(projects.isSelectable == true)
    }

    @Test("a parent that does have its own row is not synthetic, and is still selectable")
    func realParentIsNotSynthetic() throws {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "ASBA", delimiter: "/"),
            row(id: 2, name: "ASBA/ZEB", delimiter: "/"),
        ])
        let parent = try #require(nodes.first { $0.displayName == "ASBA" })
        #expect(parent.row?.id == 1)
        #expect(parent.isSelectable == true)
        #expect(parent.children.map(\.displayName) == ["ZEB"])
    }

    // MARK: - `\noselect`

    @Test("an unselectable row becomes a container node, same as a synthetic one")
    func noselectRowIsUnselectable() throws {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "Shared", delimiter: "/", isSelectable: false),
            row(id: 2, name: "Shared/Team", delimiter: "/"),
        ])
        let shared = try #require(nodes.first)
        #expect(shared.row != nil, "a \\noselect row is real -- unlike a synthetic container")
        #expect(shared.isSelectable == false)
        #expect(shared.children.map(\.displayName) == ["Team"])
    }

    // MARK: - Unsubscribed

    @Test("isSubscribed passes through from the row, and defaults true for a synthetic node")
    func isSubscribedPassesThrough() throws {
        let nodes = MailboxTree.build(from: [
            row(id: 1, name: "Archive.Old", isSubscribed: false)
        ])
        let archive = try #require(nodes.first)
        #expect(archive.row == nil)
        #expect(archive.isSubscribed == true, "a synthetic container is not itself unsubscribed")

        let old = try #require(archive.children.first)
        #expect(old.row?.isSubscribed == false)
        #expect(old.isSubscribed == false)
    }

    // MARK: - Scale

    @Test("200 mailboxes four levels deep builds a correct, complete tree")
    func largeDeepTreeIsCorrect() {
        var rows: [MailboxTreeRow] = []
        var nextId: Int64 = 1
        for top in 0..<10 {
            let topName = "Top\(top)"
            rows.append(row(id: nextId, name: topName, delimiter: "/"))
            nextId += 1
            for mid in 0..<5 {
                let midName = "\(topName)/Mid\(mid)"
                rows.append(row(id: nextId, name: midName, delimiter: "/"))
                nextId += 1
                for leaf in 0..<4 {
                    rows.append(row(id: nextId, name: "\(midName)/Leaf\(leaf)", delimiter: "/"))
                    nextId += 1
                }
            }
        }
        #expect(rows.count == 10 + 10 * 5 + 10 * 5 * 4)

        let nodes = MailboxTree.build(from: rows)
        #expect(nodes.count == 10)
        for top in nodes {
            #expect(top.depth == 0)
            #expect(top.children.count == 5)
            for mid in top.children {
                #expect(mid.depth == 1)
                #expect(mid.children.count == 4)
                for leaf in mid.children {
                    #expect(leaf.depth == 2)
                    #expect(leaf.children.isEmpty)
                    #expect(leaf.row != nil)
                }
            }
        }
    }

    @Test("an empty account has an empty tree")
    func emptyInputIsEmptyTree() {
        #expect(MailboxTree.build(from: []).isEmpty)
    }

    // MARK: - The recorded fixture

    @Test("the recorded seven-mailbox fixture builds the tree ADR-0007 expects")
    func recordedFixtureBuildsExpectedTree() throws {
        let list = try Fixture.decode(MailboxList.self, from: "mailboxes-account.json")
        #expect(list.mailboxes.count == 7)

        let rows = list.mailboxes.map { mailbox in
            MailboxTreeRow(
                id: Int64(mailbox.id),
                name: mailbox.name,
                delimiter: mailbox.delimiter,
                specialRole: mailbox.specialRole,
                isSelectable: mailbox.isSelectable,
                isSubscribed: mailbox.isSubscribed,
                unreadCount: mailbox.unread
            )
        }
        let unsubscribed = rows.filter { !$0.isSubscribed }
        #expect(unsubscribed.count == 2, "ADR-0007's test case: two of the seven are unsubscribed")

        let nodes = MailboxTree.build(from: rows)
        // Inbox, Drafts, Sent, Junk, Trash have a role; ASBA and ASBA/ZEB do not and nest.
        #expect(
            nodes.map(\.displayName) == ["INBOX", "Drafts", "Sent Items", "Junk Mail", "Deleted Items", "ASBA"]
        )
        let asba = try #require(nodes.last)
        #expect(asba.children.map(\.displayName) == ["ZEB"])
        #expect(asba.isSubscribed == false)
        let zeb = try #require(asba.children.first)
        #expect(zeb.isSubscribed == false)
    }
}
