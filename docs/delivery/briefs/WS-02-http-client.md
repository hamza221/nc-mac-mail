<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-02 — HTTP client, endpoints, models, decoding

**Wave 1, after WS-00. Size: L. Parallel with WS-01 and WS-03.**

## Goal

Every payload this app touches, decoded into `Sendable` value types, behind a client that
handles the Mail app's error shapes, retries what is safe, and can be swapped for a fake in
tests.

## Before you start

- [../../reference/api-payloads.md](../../reference/api-payloads.md) — **the whole file, including the four traps**
- [../../architecture/networking.md](../../architecture/networking.md)
- [../../../plan/API.md](../../../plan/API.md) — the complete endpoint map
- [../testing-strategy.md](../testing-strategy.md) — fixtures come from a real server

## You own

`Packages/NCMailNet/Sources/NCMailNet/{Client,Endpoints}/**`,
`Packages/NCMailCore/Sources/NCMailCore/Models/**`

## Build

**Models** in `NCMailCore` — all `Sendable`, all value types, all `Decodable` with explicit
`CodingKeys`:

`Account`, `Mailbox`, `Envelope`, `MessageFlags`, `MessageBody`, `Attachment`, `Address`,
`Tag`, `SyncResponse`, `MailboxStats`, `Capabilities`.

The traps, restated because they are decoding bugs waiting to happen:

- `Mailbox.id` is base64 of the name. **Decode `databaseId` as the identifier and ignore
  `id`.**
- `Mailbox.displayName` is the full path, not the leaf.
- Subscription is `attributes.contains` of `\subscribed`, compared **case-insensitively**;
  `\noselect` means not selectable.
- `specialRole` is a string **or the integer 0**.
- Envelope `flags` is an **object** with keys including `$junk`, `$notjunk`, `$mdnsent`.
  Body `flags` is an **array**. Two types; do not share one.
- `references` is `null` or an array, never a string.
- `tags` is a dictionary keyed by IMAP label.
- Attachment `id` is a **string**.
- Every model keeps its raw JSON so the store can persist `rawJSON` — decode into a
  `RawBacked<T>` wrapper or carry `rawData: Data` alongside; pick one and be consistent.

**Client** in `NCMailNet`:

```swift
public protocol MailTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct MailClient: Sendable {
    public init(server: URL, credentials: Credentials, transport: any MailTransport = URLSessionTransport())
    public func get<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T
    public func post<T: Decodable & Sendable>(_ endpoint: Endpoint<T>, body: (some Encodable & Sendable)?) async throws -> T
    public func put<T: Decodable & Sendable>(_ endpoint: Endpoint<T>, body: (some Encodable & Sendable)?) async throws -> T
    public func delete<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T
    public func bytes(_ endpoint: Endpoint<Data>) async throws -> (Data, HTTPURLResponse)
}
```

- Headers on every request: `Authorization: Basic …`, `OCS-APIRequest: true`,
  `Accept: application/json`, versioned `User-Agent`.
- `URLSessionConfiguration`: **cookies off** (`httpCookieAcceptPolicy = .never`,
  `httpShouldSetCookies = false`) — a stray cookie turns a working request into a 412.
- `MailError` exactly as in [../../architecture/networking.md](../../architecture/networking.md),
  including `decoding(_:endpoint:)`, which carries the endpoint name because that is the
  only question worth answering first at 3 a.m.
- Retry `GET` and `POST …/sync` only: 2 s, 8 s, 30 s, jittered. **Never auto-retry a
  mutation** — that is the drainer's job.
- Honour `Retry-After` on 429 and 503.

**Endpoints** — one `Endpoint<T>` per call in `Endpoints.swift`, so URL building and
escaping live in one reviewable file. v1 needs: accounts, mailboxes, messages index,
message body, message html (`plain=true`), message thread, sync, flags, move, delete,
thread move, thread delete, attachment download, avatar image, trusted senders,
capabilities, preferences.

Percent-encode address-keyed paths properly. `+` in an address is real and is a real bug.

## Acceptance

- Every fixture in `NCMailTestSupport` decodes, with a test per model.
- A deliberately malformed payload produces `MailError.decoding` naming the endpoint, not a
  crash.
- A 202 sync response maps to `.syncInProgress`; a 428 to `.mailboxNotCached`; a 400 with
  the `fail` envelope to `.mailboxNotCached` when it carries that message.
- Retries: `GET` retries three times then throws; a `PUT` does not retry at all.
- `MailClient` is `Sendable` and usable from an actor without warnings.
- No test in this workstream touches the network.

## Out of scope

Login (WS-01). Database (WS-03). Any sync logic (WS-04/05). Recording fixtures — that is
WS-14, and you may need to coordinate on timing: if fixtures do not exist yet, record a
minimal set yourself with `Scripts/record-fixtures.sh` and hand them over.

## Report

Additionally: every place the real payload differed from
[../../reference/api-payloads.md](../../reference/api-payloads.md) — **and the correction,
made in that file, in this pull request**.
