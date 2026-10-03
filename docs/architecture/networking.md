<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Networking

*Authentication, the HTTP client, and how to behave on someone else's server. Owned by
`NCMailNet` (WS-01, WS-02).*

## Authentication

App password over HTTP Basic, obtained through Login Flow v2.
[ADR-0002](../decisions/0002-app-password-login-flow-v2.md) explains why, and why it works
against routes that otherwise demand a CSRF token.

### The flow

```
1.  POST {server}/index.php/login/v2                     (no auth)
    User-Agent: Nextcloud Mail (macOS)     ← becomes the app-password name in the
    → {"login": "https://…", "poll": {"token": "…", "endpoint": "https://…"}}   user's settings

2.  NSWorkspace.shared.open(login)

3.  POST poll.endpoint   body: token=<token>     every 2 s, give up after 5 min
    → 404 while the user is still in the browser
    → 200 {"server": "…", "loginName": "…", "appPassword": "…"}

3b. GET {server}/index.php/apps/mail/api/accounts, with the app password just returned.
    A 404 here — not a 401 — is the only signal that distinguishes "right credential, no
    Mail app" from every other failure, so `LoginFlow` checks it before reporting success
    rather than leaving it for the mirror coordinator to discover later. See
    [ADR-0019](../decisions/0019-login-flow-verifies-the-mail-app.md).

4.  Keychain: kSecClassInternetPassword, keyed by host + loginName, scoped by
    kSecAttrSecurityDomain = com.nextcloud.mail.macos (ADR-0059). `LoginFlow` never
    writes this itself — it hands back `Credentials`, and the caller decides whether the
    sign-in counts as complete before storing it.
```

### Every subsequent request

```
Authorization: Basic base64(loginName:appPassword)
OCS-APIRequest: true
Accept: application/json
User-Agent: Nextcloud Mail (macOS)/<version>
```

`OCS-APIRequest: true` is load-bearing on the non-OCS `/api/` routes:
`passesCSRFCheck()` in `lib/private/AppFramework/Http/Request.php` returns true as soon as
that header is present, and `cookieCheckRequired()` is false for a request with no session
cookie. Which also means: **never let a session cookie into this client's cookie jar.**
Use an ephemeral `URLSessionConfiguration` with `httpCookieAcceptPolicy = .never` and
`httpShouldSetCookies = false`. A stray cookie turns a working request into a 412.

### Before any Swift is written

WS-01 runs this against a real instance and pastes the output into its PR:

```sh
Scripts/smoke-auth.sh https://cloud.example.com user 'app-password'
```

A JSON array of accounts means the plan holds. A 412 or a CSRF error means the fallback is
a session cookie plus a scraped `requesttoken`, and WS-01 stops and reports rather than
improvising — that change would reshape several workstreams.

## The client

```swift
public struct MailClient: Sendable {
    public init(server: URL, credentials: any MailCredentials,
                transport: any MailTransport = URLSessionTransport(),
                retryPolicy: RetryPolicy = .standard)

    public func get<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T
    public func post<T: Decodable & Sendable>(_ endpoint: Endpoint<T>, body: (some Encodable & Sendable)?) async throws -> T
    public func put<T: Decodable & Sendable>(_ endpoint: Endpoint<T>, body: (some Encodable & Sendable)?) async throws -> T
    public func patch<T: Decodable & Sendable>(_ endpoint: Endpoint<T>, body: (some Encodable & Sendable)?) async throws -> T
    public func delete<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T
    public func bytes(_ endpoint: Endpoint<Data>) async throws -> (Data, HTTPURLResponse)
    public func upload<T: Decodable & Sendable>(_ endpoint: Endpoint<T>, multipart: MultipartForm) async throws -> T
}
```

`credentials` is `any MailCredentials`, a protocol with `loginName` and `appPassword`.
WS-01's `Credentials` conforms to it, so a value loaded from the Keychain goes straight in.
The protocol exists so the client half and the auth half of `NCMailNet` could be built at
the same time without depending on each other's concrete types.

The client takes a `MailTransport` rather than a `URLSession`, so a test never reaches the
network; `URLSession.mail` is what the default transport wraps.

A value type, `Sendable`, no shared mutable state, cheap to hand to an actor. Paths are
relative to `{server}/index.php/apps/mail/api/`; OCS endpoints and
`/ocs/v2.php/cloud/capabilities` take an absolute form.

`Endpoint<T>` is a small struct — method, path, query, response type — defined once per
endpoint: the v1 routes in `Endpoints.swift`, the v2 surface (WS-16) in
`Endpoints+Accounts.swift`, `+Mailboxes`, `+Messages`, `+Compose`, `+Settings` and `+OCS`,
one file per `plan/API.md` area. Call sites read as `try await client.get(.mailboxes(accountId: 3))`,
which keeps URL construction and its escaping in reviewable files. Address-keyed paths
(`/api/avatars/image/{email}`) percent-encode the address; `+` in an address is a real
character and a real bug waiting to happen.

v2 additions (WS-16):

- **`patch`** for `PATCH /api/accounts/{id}` and `PATCH /api/mailboxes/{id}`; nil fields
  are omitted from the body so only what was sent changes.
- **`upload(_:multipart:)`** for the two `multipart/form-data` routes, `POST
  /api/attachments` and `POST /api/smime/certificates`. `MultipartForm` is hand-rolled
  (RFC 7578, random boundary per form). Both are mutations and go out once.
- **A response type is what the route really answers**, verified live, not `EmptyResponse`
  by default: tag add/remove answer the tag, mailbox PATCH the mailbox, delegation grant the
  delegation. `EmptyResponse` is kept for routes whose body is `[]`, `data: null` or a
  status string.
- **`EmptyBodyRepresentable`** — a 204 or an empty 200 never reaches `JSONDecoder`; a
  type that can say "nothing there" opts in (`EmptyResponse`, `JSONEnvelope<T?>`, the LLM
  responses, which answer 204 when the server has no provider).
- **`JSONEnvelope<T>`** models Mail's `{"status","data"}` wrapper, with `status` optional
  because `GET /api/accounts/{id}/test` omits it.
- OCS routes outside Mail use `base: .server` and the `OCSResponse<T>` wrapper.

Per-route shapes and statuses: [api-payloads.md](../reference/api-payloads.md#v2-mail-routes-what-the-live-server-answers-ws-16).

### Transport seam

```swift
public protocol MailTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

`MailClient` holds a `MailTransport`. Production is `URLSession`; tests use
`FakeTransport`, which replays recorded fixtures and can be told to fail, stall, or return
429. This seam is why most of the sync engine is testable without a server, and WS-02 owns
it — see [../delivery/testing-strategy.md](../delivery/testing-strategy.md).

## Errors

The Mail app answers failures in two different shapes, and both must be handled:

```json
{"status": "error", "data": {"message": "…"}}      // JsonResponse::fail, any 4xx/5xx
```
```json
{"message": "…"}                                     // plain controller responses
```

Statuses with meaning in this app (full table in
[sync-engine.md](sync-engine.md#errors)): **202** work in progress — *unless* the body is
the success envelope, which is how drafts and outbox answer update, delete, move and send
([ADR-0077](../decisions/0077-a-202-with-the-success-envelope-is-success.md)) — **400**
often `MailboxNotCachedException`, **403** delegation or account gone, **412** the CSRF
path went wrong, **428** mailbox not cached, **429** rate limited.

```swift
public enum MailError: Error, Sendable {
    case unauthorized                       // 401 → re-login
    case forbidden                          // 403
    case notFound                           // 404/410 → the thing is gone
    case mailboxNotCached                   // 400 with that shape, or 428
    case syncInProgress                     // 202 without the success envelope
    case rateLimited(retryAfter: Duration?)  // 429/503
    case server(status: Int, message: String?)
    case transport(any Error)               // offline, TLS, timeout
    case decoding(any Error, endpoint: String)
}
```

`decoding` carries the endpoint name because a server-shape change shows up as a decode
failure in a background actor at three in the morning, and "which endpoint" is the only
question worth answering first.

## Retry and rate limits

- **Retry** only idempotent reads automatically: `GET`, and `POST /sync` (which is a read
  dressed as a write). Three retries, waiting 2 s, 8 s and 30 s, so at most four sends.
  Full jitter: each wait is a uniform pick between zero and the figure above, which spreads
  a herd better than adding a small random tail. Retryability is a property of the endpoint
  rather than of the verb, because `POST …/sync` retries and `POST …/move` must not.
  v2 adds one more read dressed as a POST, `POST /api/follow-up/check-message-ids`, which
  retries; and one GET that deliberately does not: the account connection test
  (`GET /api/accounts/{id}/test`), whose answer *is* the diagnostic — a silent retry would
  hide the flakiness the user asked about.
- **Retry only what another attempt could fix**: a transport failure, a 429 or 503, or a
  5xx. A 403 or a 404 will answer the same way forever, and a **202 is not retried by the
  client** — it surfaces as `.syncInProgress` and the sync engine decides when to ask again,
  because only it knows what window it sent.
- **Never auto-retry a mutation.** That is the drainer's job, with its own policy
  ([offline-queue.md](offline-queue.md)), because only it knows what was already applied
  locally.
- **Honour `Retry-After` exactly.** Several Mail endpoints are rate limited server-side:
  the image proxy at 50/60 s, autoconfig at 5/60 s, mailbox repair at 10/600 s.
- **Halve concurrency for ten minutes** after any 429. A client that backs off politely
  gets to keep its backfill.
- **Offline is not an error.** `NWPathMonitor` says the network is down: pause the
  schedulers, stop making requests, show one indicator. Do not emit fifty timeouts.

## Concurrency budget

| Work | Limit |
| --- | --- |
| Body backfill | 2 per account, 4 total |
| Envelope pages | 1 per mailbox, 2 per account |
| Interactive fetch (user opened something) | Unlimited, and it preempts a backfill slot |
| Mutation drain | 1 per account |
| Avatars | 4 total, lowest priority |

One `URLSession` for the app, `httpMaximumConnectionsPerHost = 6`, `waitsForConnectivity`
off (we manage that ourselves), `timeoutIntervalForRequest = 60`,
`timeoutIntervalForResource = 300` — a `/body` on a cold IMAP server is genuinely slow.

## TLS

System defaults. No certificate pinning: users run self-hosted instances with every
imaginable certificate arrangement, and pinning breaks them for no attacker we are
defending against ([security.md](security.md)). A self-signed certificate fails, visibly,
with an explanation — we do not offer "trust anyway" in v1.

## DAV (WS-17)

CardDAV, CalDAV and the WebDAV verbs live in `NCMailNet/DAV`, behind the same
`MailTransport` seam as `MailClient`. The DAV routes are `{server}/remote.php/dav/…`; they
take the same Basic auth, the same cookie rules, and the same User-Agent as every other
request. XML is parsed with Foundation's `XMLParser` — no new dependency.

```swift
public struct DAVClient: Sendable {
    public init(server: URL, credentials: any MailCredentials,
                transport: any MailTransport = URLSessionTransport())

    public func propfind(_ url: URL, depth: DAVDepth, properties: [DAVQualifiedName]) async throws -> [DAVResource]
    public func report(_ url: URL, body: Data, depth: DAVDepth) async throws -> DAVMultistatus
    public func syncCollection(_ url: URL, token: String?) async throws -> DAVSyncChanges
    public func addressbookMultiget(_ url: URL, hrefs: [String]) async throws -> [DAVResource]
    public func calendarMultiget(_ url: URL, hrefs: [String]) async throws -> [DAVResource]
    public func put(_ url: URL, data: Data, contentType: String, ifMatch: String?) async throws -> String?
    public func delete(_ url: URL, ifMatch: String?) async throws
    public func mkcolExtended(_ url: URL, resourceTypes: [DAVQualifiedName], properties: [DAVProposedProperty]) async throws
    public func proppatch(_ url: URL, set: [DAVProposedProperty], remove: [DAVQualifiedName]) async throws
    public func share(_ url: URL, with principal: String, readOnly: Bool) async throws
    public func currentUserPrincipal() async throws -> URL
    public func homeSets(of principal: URL) async throws -> DAVHomeSets
}
```

Behaviour, as measured against Nextcloud 36 (sabre/dav):

- **Principal discovery** is two PROPFINDs: `current-user-principal` on `/remote.php/dav/`
  (Depth 0), then `card:addressbook-home-set` and `cal:calendar-home-set` on the principal.
  Hrefs come back host-relative and are resolved against the server root. Observed live
  for `admin`: principal `/remote.php/dav/principals/users/admin/`, addressbook home
  `/remote.php/dav/addressbooks/users/admin/`, calendar home
  `/remote.php/dav/calendars/admin/` — note no `users/` segment on the calendar side, so
  never derive one home from the other; always ask the principal. The addressbook home
  also lists Nextcloud's synthetic books (`z-server-generated--system`,
  `z-app-generated--contactsinteraction--recent`). `DAVLiveTests.discoversTheLivePrincipal`
  keeps this runnable (`NCMAIL_LIVE_DAV=…`).
- **`syncCollection`** is RFC 6578. An empty `<d:sync-token/>` is the initial sync. The
  answer separates changed resources (propstat with `getetag`) from removed ones (a bare
  `<d:response>` whose status is 404). A **truncated** sync is *not* an HTTP 507: the
  server answers 207 with one extra `<d:response>` for the collection itself carrying
  `HTTP/1.1 507 Insufficient Storage`, plus a token that resumes where it stopped.
  `DAVSyncChanges.truncated` surfaces that; the sync engine (WS-24) loops until it clears
  (ADR-0076). The recorded truncation was provoked with `<d:limit><d:nresults>1`; the
  client itself sends no limit.
- **`put` returns the new ETag when the header is present and nil when it is not.** RFC
  4791 §5.3.4 and RFC 6352 §6.3.2.3 forbid a strong ETag when the stored body differs
  from the one sent. Nextcloud returns one anyway — measured live: a vCard 4.0 PUT is
  re-served as sabre-normalised vCard 3.0, yet the PUT answers
  `ETag: "<md5 of the bytes we sent>"` and
  a later GET carries the same ETag over the converted bytes. So a present ETag is valid
  for `If-Match`, but it does **not** prove the server holds our bytes: the caller must
  re-read (multiget) any card it did not write as 3.0 before treating its local copy as
  the stored one. A nil ETag means the same, unconditionally.
- **Writes carry `If-Match`** when the caller holds an ETag. A 412 surfaces as
  `DAVError.preconditionFailed`; the recovery (refetch, reapply edited properties) is the
  sync engine's, per ADR-0069.
- **`share`** is the Nextcloud `oc:share` POST against the collection URL, with
  `<d:href>principal:principals/users/…</d:href>` and `<o:read-write/>` unless read-only.
  The server answers 200 with an empty body.
- **No automatic retry.** Unlike `MailClient`, `DAVClient` never retries: the contacts and
  calendar sync engine owns its own schedule and a multistatus is too expensive to repeat
  on a guess. Failures map to `DAVError`, which parses sabre's `d:error`
  (`s:exception`/`s:message`) body when one is present.

Fixtures for all of this are recorded from a live server by `Scripts/record-fixtures.sh`
(the `dav-*.xml`, `contact-*.vcf` and `*.ics` files); the vCard and iCalendar bytes are
stored verbatim because the format round-trip tests compare bytes.
