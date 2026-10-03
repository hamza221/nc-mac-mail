// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// One message stage 2 still owes a body, with both of the ids that takes.
///
/// Two ids rather than one because the two halves of the work need different ones:
/// `GET /messages/{id}/body` takes the server's ``remoteId``, and the row the answer is
/// written back to is found by the mirror's ``id``. Before
/// [ADR-0033](../../../../docs/decisions/0033-accounts-have-a-local-identity.md) they were
/// the same number, which is exactly the assumption that broke with a second server.
public struct BodyBackfillItem: FetchableRecord, Decodable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var remoteId: Int64

    public init(id: Int64, remoteId: Int64) {
        self.id = id
        self.remoteId = remoteId
    }
}
