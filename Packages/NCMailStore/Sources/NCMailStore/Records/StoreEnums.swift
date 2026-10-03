// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// Where an account's mirror has got to, rolled up from its mailboxes.
///
/// `paused` and `failed` are stored in the same column rather than as flags because the
/// sidebar shows one word per account and a row with two truths would need a rule to pick.
public enum MirrorState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case idle
    case priming
    case envelopes
    case bodies
    case complete
    case paused
    case failed
}

/// Whether a message's body is in the mirror, and if not, why not.
public enum BodyState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case missing
    case queued
    case fetching
    case present
    case failed
}

/// The header a stored address came from.
public enum AddressKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case from
    case to
    case cc
    case bcc
    case replyTo
}

/// A queued mutation's position in the drain cycle.
public enum PendingOperationState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case pending
    case inFlight
    case failed
}

/// Flat or grouped by thread.
///
/// Both are queries over the same rows: the server's `view=threaded` is never used for
/// enumeration ([ADR-0014](../../../../docs/decisions/0014-singleton-enumeration.md)), so
/// this is purely a local display choice.
public enum ListView: String, Codable, Sendable, CaseIterable {
    case flat
    case threaded
}
