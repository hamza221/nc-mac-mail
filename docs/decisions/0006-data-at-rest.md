# ADR-0006: Sandbox container plus FileVault, not an encrypted database

**Status:** Accepted, with a named trigger to revisit
**Date:** 2026-09-21
**Decided by:** Product owner, from an explicit three-way choice

## Context

[ADR-0003](0003-local-first-full-mirror.md) puts potentially every message a user has ever
received onto their disk. That deserves a deliberate answer rather than a default.

## Decision

The mirror is **plain SQLite inside the app's sandbox container**, protected by macOS file
permissions and FileVault. The app password stays in the Keychain. The threat model is
written down in [../architecture/security.md](../architecture/security.md) and stated in
the app's own help, rather than left for a user to discover.

This is what Apple Mail does with the same data.

## Consequences

- No extra dependency, no key management, no key rotation, no "the database will not open"
  support class.
- With FileVault on — the default since macOS 11, and effectively universal on managed
  fleets — the mail is encrypted at rest with the system's own protection.
- With FileVault off, an attacker with the powered-off machine can read the mirror. We say
  so plainly instead of implying protection we do not provide.
- An attacker with the *unlocked* machine can read the mail either way, and no application
  can change that.

## Alternatives considered

**SQLCipher (via GRDB-SQLCipher).** Encrypts the database with a key in the Keychain.
Rejected for v1 because it protects a narrow slice: only while the app is not running, and
only against an attacker who has the disk but cannot open the Keychain — which the same
login password unlocks. Costs a C dependency, a custom GRDB build, key rotation, a wipe
path, and a new failure mode. Real cost, small marginal risk reduction over FileVault.

**Envelopes on disk, bodies in memory only.** Coherent only with a shallow cache, and
incompatible with the mirror we chose. Subjects and senders are most of the sensitive
metadata anyway.

**Encrypt only message bodies with a Keychain key.** Half the cost of SQLCipher and most of
its weaknesses, plus it breaks FTS: an index over encrypted text is either useless or
leaks the text.

## Revisit when

Any of these, and the work is a few days with GRDB-SQLCipher plus a migration path:

- Nextcloud requires encryption at rest for a supported client.
- The app targets a deployment where FileVault cannot be assumed.
- A multi-user Mac scenario appears where container permissions are the only barrier.
