<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0021: One `MessageFlags` type for the envelope and the body

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-02, against a live Nextcloud 36.0.0 running Mail 5.12.0-rc.1

## Context

The WS-02 brief and `docs/reference/api-payloads.md` both said envelope `flags` is an object
and body `flags` is an array, and both instructed: "Two types; do not share one."

The server disagrees. Against the version the document cites:

```
GET /api/messages?mailboxId=5&limit=1   → .[0].flags | type  →  "object"
GET /api/messages/66/body               → .flags     | type  →  "object"
```

`IMAPMessage::getFlags()` returns a PHP associative array, and an associative array
serialises as a JSON object. The two responses do differ, but in their keys: the envelope
has `$junk` and `$notjunk`, the body does not. Both have `$mdnsent`.

There is a third form. `PUT /api/messages/{id}/flags` takes a flag-name map, and flag names
also appear as bare arrays elsewhere in the Mail app's history.

## Decision

One `MessageFlags` type, decoded from either an object or an array of flag names. `junk`,
`notJunk` and every other member default to false when the key is absent, so the body's
nine-key object and the envelope's eleven-key object both decode without a special case. An
unrecognised flag name in the array form is ignored rather than fatal.

`docs/reference/api-payloads.md` is corrected in the same change, and the "two types" item
is removed from the list of traps.

## Consequences

`Envelope.flags` and `MessageBody.flags` are the same type, so the message view and the list
row read `flags.seen` the same way and the store writes one set of columns.

`flags.junk` read off a `MessageBody` is always false, because the body does not report it.
That is a real trap in the other direction: junk state comes from the envelope. The type's
doc comment says so.

Tolerating the array form is code that no current server exercises. It is about fifteen
lines and one test, and it is the difference between an older or patched server rendering
mail and failing to decode anything.

A server that starts sending a flag we do not know about is silently ignored rather than
rejected. For reading mail that is the right trade; a new flag must not break the inbox.

## Alternatives considered

**Two types, as the brief said.** It would have been modelling the document rather than the
server. The array type would never be constructed, and the first person to debug
`MessageBodyFlags` would find it had no decode path that ever ran.

**Decode the object form only, and let the array form throw.** `MailError.decoding` names
the endpoint, so the failure would be legible. But it fails at the point where the user
wanted to read a message, and the fix is fifteen lines written in advance.

**Keep `flags` as `AnyJSON` and interpret later.** Pushes the same branching into every
caller.

## Revisit when

A server is found that really does send an array here, which would make the lenient path
load-bearing and worth a recorded fixture; or the Mail app adds `$junk` to the body
response, at which point the "always false on a body" caveat goes away.
