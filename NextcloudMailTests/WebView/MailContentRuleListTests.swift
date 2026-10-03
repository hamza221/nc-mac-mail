// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import WebKit

@testable import NextcloudMail

/// The one thing about the rule list that can be checked without a window: that WebKit
/// accepts it.
///
/// Whether the compiled list actually intercepts a custom-scheme load is a question only a
/// running WebView can answer, and this workstream could not run one — see the report.
@Suite("Content rule list")
@MainActor
struct MailContentRuleListTests {
    @Test("WebKit compiles the rule list the WebView is given")
    func compiles() async throws {
        let list = try await MailContentRuleList.compiled()
        #expect(list.identifier == MailContentRuleList.identifier)
    }

    @Test("it is compiled once and shared, not once per message")
    func isCompiledOnce() async throws {
        let first = try await MailContentRuleList.compiled()
        let second = try await MailContentRuleList.compiled()
        #expect(first === second)
    }

    @Test("the rule order is block everything, then take it back for our scheme")
    func ruleOrderIsBlockThenException() throws {
        let data = Data(MailContentRuleList.json.utf8)
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(rules.count == 2)
        let first = try #require(rules.first)
        let firstTrigger = try #require(first["trigger"] as? [String: Any])
        let firstAction = try #require(first["action"] as? [String: Any])
        #expect(firstTrigger["url-filter"] as? String == ".*")
        #expect(firstAction["type"] as? String == "block")

        let second = try #require(rules.last)
        let secondTrigger = try #require(second["trigger"] as? [String: Any])
        let secondAction = try #require(second["action"] as? [String: Any])
        #expect(secondTrigger["url-filter"] as? String == "^ncmail://asset/")
        #expect(secondAction["type"] as? String == "ignore-previous-rules")
    }
}
