<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-01 — Login Flow v2, Keychain, session

**Wave 1, after WS-00. Size: M. Parallel with WS-02 and WS-03.**

## Goal

Sign in through the browser, store an app password in the Keychain, and hand a credentialed
session to the rest of the app — with the CSRF assumption verified against a real server
**before** any Swift is written.

## Before you start

- [../../decisions/0002-app-password-login-flow-v2.md](../../decisions/0002-app-password-login-flow-v2.md)
- [../../architecture/networking.md](../../architecture/networking.md) — auth section
- [../../architecture/security.md](../../architecture/security.md)
- [../../product/user-stories.md](../../product/user-stories.md) — S-01

## Step 0, before anything else

```sh
Scripts/smoke-auth.sh https://cloud.example.com user 'app-password'
```

A JSON array of accounts means the plan holds — paste it into the pull request. A **412**
or a CSRF error means the whole authentication approach needs to change to a session cookie
plus a scraped `requesttoken`, which reshapes several workstreams: **stop, report, and do
not improvise a workaround.**

## You own

`Packages/NCMailNet/Sources/NCMailNet/Auth/**`, `NextcloudMail/Views/Login/**`

## Build

```swift
public actor LoginFlow {
    public enum State: Sendable { case idle, awaitingBrowser(URL), polling, succeeded(Credentials), failed(LoginError) }
    public func start(server: URL) async throws -> URL      // POST /index.php/login/v2
    public func awaitCompletion() async throws -> Credentials // poll every 2s, 5 min ceiling
    public func cancel()
}

public struct Credentials: Sendable, Equatable {
    public let server: URL
    public let loginName: String
    public let appPassword: String     // never logged, never in a description
}

public enum Keychain {
    public static func save(_ credentials: Credentials) throws
    public static func load(server: URL, loginName: String) throws -> Credentials?
    public static func delete(server: URL, loginName: String) throws
    public static func allAccounts() throws -> [(server: URL, loginName: String)]
}
```

Details that are not optional:

- `User-Agent: Nextcloud Mail (macOS)` on the flow's first request — it names the app
  password in the user's security settings.
- Open the login URL with `NSWorkspace.shared.open`.
- Poll `POST poll.endpoint` with form body `token=…` every 2 s. 404 means keep waiting.
- Keychain item: `kSecClassInternetPassword`, `kSecAttrServer` = host,
  `kSecAttrAccount` = login name, `kSecAttrAccessibleAfterFirstUnlock`.
- `Credentials` gets a `CustomStringConvertible` that prints `Credentials(server:…, loginName:…)`
  and never the password. A credential in a crash log is a security incident.

**Server URL normalisation** is its own tested function: accept `cloud.example.com`,
`https://cloud.example.com`, trailing slashes, a path prefix
(`https://example.com/nextcloud`), and reject anything that is not http(s). This is the
first thing a user types and the first thing that goes wrong.

**`LoginView`** — a server field, a Continue button, the waiting state with Cancel, and
three distinguishable failures: unreachable, not a Nextcloud instance, Mail app not
installed. `NCButtonStyle.primary` on Continue, `NCNoteCard(.error)` for failure.

## Acceptance

- Sign in end to end against a real instance.
- The app password appears in Nextcloud's security settings as **Nextcloud Mail (macOS)**.
- Relaunch does not ask again.
- Sign out removes the Keychain item; the next launch asks.
- Cancelling mid-flow leaves nothing behind.
- Five minutes with no browser action gives a clear timeout and a retry, not a dead screen.
- A grep for the password across logs, `description`s and crash metadata finds nothing.

## Out of scope

The generic HTTP client and endpoints (WS-02 — you may use `URLSession` directly for the
four login requests). Account listing beyond proving the credential works. Multi-account
switching UI (WS-13).

## Report

Additionally: the step-0 output; whether the `OCS-APIRequest` header alone was sufficient;
and whether `SecItem` behaved under the sandbox configuration WS-00 left in place.
