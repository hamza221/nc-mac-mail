// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailNet

@Suite("Credentials")
struct CredentialsTests {
    @Test("description never contains the app password")
    func descriptionHidesPassword() throws {
        let server = try #require(URL(string: "https://cloud.example.com"))
        let credentials = Credentials(server: server, loginName: "alice", appPassword: "super-secret-token")

        let described = credentials.description
        let interpolated = "\(credentials)"

        #expect(!described.contains("super-secret-token"))
        #expect(!interpolated.contains("super-secret-token"))
        #expect(described.contains("alice"))
        #expect(described.contains("cloud.example.com"))
    }
}
