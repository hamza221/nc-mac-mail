// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet

extension MailClient {
    /// A client wired to a fake transport, with a retry policy that records the
    /// waits instead of taking them. No test in this workstream sleeps.
    static func testing(
        transport: any MailTransport,
        delays: [Duration] = RetryPolicy.standard.delays,
        recorder: DelayRecorder = DelayRecorder()
    ) -> MailClient {
        MailClient(
            server: URL(string: "https://cloud.example.com")!,
            credentials: BasicCredentials(loginName: "alice", appPassword: "secret"),
            transport: transport,
            retryPolicy: RetryPolicy(
                delays: delays,
                // Identity jitter: the schedule is what the test asserts on.
                jitter: { $0 },
                sleep: { await recorder.record($0) }
            ),
            clientVersion: "test"
        )
    }
}

/// Collects the delays a retry would have slept for.
actor DelayRecorder {
    private(set) var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }
}
