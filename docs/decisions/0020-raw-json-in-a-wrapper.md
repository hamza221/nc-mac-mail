<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0020: Carry the server's JSON in a wrapper, not in every model

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-02, choosing between the two options its brief offered

## Context

[ADR-0003](0003-local-first-full-mirror.md) keeps a full local mirror, and
[schema.sql](../reference/schema.sql) gives `account`, `mailbox`, `message` and
`messageBody` a `rawJSON TEXT NOT NULL` column. The point of the column is the fields the
client does not model: a server-side addition shows up in the mirror without a schema
migration, and a feature added later can read it out of rows that were synced before anyone
thought of it.

That only works if decoding keeps the original JSON. The WS-02 brief named two ways to do
it and asked for one, consistently: a `RawBacked<T>` wrapper, or a `rawData: Data` field on
every model.

`Decodable` cannot hand a type the byte range it occupied. An element of a 95-entry array
has no way to ask for its own slice of the response, so "keep the original bytes" is not
literally available to either option.

## Decision

`RawBacked<Value>` holds the decoded model and an `AnyJSON` tree of everything that was
sent. Only the calls whose result the store persists are wrapped —
`[RawBacked<Account>]`, `[RawBacked<Envelope>]`, `RawBacked<MessageBody>`, and the
`entries` of a `MailboxList`. `MailboxStats`, `Capabilities` and `Preference` are not
wrapped, because nothing persists them.

`rawJSON()` re-encodes the `AnyJSON` with sorted keys rather than returning the original
bytes. `AnyJSON` keeps integers as integers so an id does not round-trip through `Double`.

## Consequences

The models stay plain value types. A test builds an `Envelope` without inventing bytes for
it, a view holds one without carrying a payload it will never read, and `Equatable` compares
values rather than formatting.

The stored JSON is canonicalised, not byte-identical: key order is sorted and whitespace is
gone. Nothing in the app compares it against a server response, and two recordings of one
payload now compare equal, which makes fixture drift visible. But anyone who later wants a
signature or a hash over the exact bytes the server sent will not find them here.

Call sites read `.value` to get the model. That is the visible cost, and it is why the
wrapper is applied only where the column exists.

Every payload is parsed twice, once into the model and once into `AnyJSON`. Decoding the
whole 95-envelope inbox page takes 0.135 s in the test suite, including reading the file, so
this has not been optimised and should not be until someone measures a backfill and writes
the number down.

## Alternatives considered

**`rawData: Data` on every model.** Every model becomes non-constructible without bytes,
every test fixture has to carry them, and models with no `rawJSON` column pay anyway. The
`Data` would also have to be produced by re-encoding, so it buys no extra fidelity.

**Decode twice at the call site**, once into the model and once into a JSON tree. Same work,
but the pairing is by convention rather than by type, and the first caller to forget it
writes an empty `rawJSON` that nobody notices until the column is needed.

**Store the whole response body** and slice it later. The store needs a row per object, not
a blob per request, and slicing means re-parsing to find offsets.

## Revisit when

A backfill profile shows `AnyJSON` decoding as a measurable share of the time, or something
genuinely needs the exact bytes the server sent — a signature check, or a diff against a
recorded fixture that is expected to be byte-equal.
