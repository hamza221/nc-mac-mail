// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet

/// One canned answer for every request, and nothing else.
///
/// `NCMailTestSupport.FakeTransport` is the richer version of this and is what the package
/// tests use, but it is a product the app target must never link
/// (`Packages/NCMailTestSupport/Package.swift` says so, and ADR-0029 explains why the app's
/// test bundle keeps to that). The app-side tests that need a transport need one response,
/// so they get twenty lines instead of the package.
struct ReplayTransport: MailTransport {
    enum Answer: Sendable {
        case response(status: Int, body: Data)
        /// Offline, a timeout, a TLS failure: whatever the client sees as `.transport`.
        case failure(URLError.Code)
    }

    let answer: Answer

    static func replaying(_ body: Data, status: Int = 200) -> ReplayTransport {
        ReplayTransport(answer: .response(status: status, body: body))
    }

    static func answering(status: Int) -> ReplayTransport {
        ReplayTransport(answer: .response(status: status, body: Data()))
    }

    static let offline = ReplayTransport(answer: .failure(.notConnectedToInternet))

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch answer {
        case .failure(let code):
            throw MailError.transport(URLError(code))
        case .response(let status, let body):
            guard
                let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )
            else { throw MailError.transport(URLError(.badServerResponse)) }
            return (body, response)
        }
    }
}
