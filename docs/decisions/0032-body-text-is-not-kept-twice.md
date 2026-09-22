<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0032: `messageBody.rawJSON` drops the `body` field

**Status:** Accepted — narrows [ADR-0020](0020-raw-json-in-a-wrapper.md) for one column
**Date:** 2026-09-22
**Decided by:** WS-04, from a `dbstat` breakdown of a full mirror of the live account

## Context

[ADR-0020](0020-raw-json-in-a-wrapper.md) gives `account`, `mailbox` and `message` — and, in
the schema, `messageBody` — a `rawJSON` column holding everything the server sent, so a
field the client does not model yet survives a sync and can be read later without a refetch.
Good trade on an envelope, which is a few hundred bytes of metadata.

WS-04 mirrored the live account to a file and asked `dbstat` where the bytes went. For 155
messages, 10.98 MB after `VACUUM`:

| Table | Bytes | Per message |
| --- | --- | --- |
| `messageBody` | 9,506,816 | 61.3 KB |
| `messageSearch` (content + data) | 978,944 | 6.3 KB |
| `message` | 299,008 | 1.9 KB |
| everything else | ~195,000 | 1.3 KB |

The `messageBody` figure did not match the text it was storing. Broken down by column:

```sql
SELECT sum(length(html))                         FROM messageBody;  -- 4,441,501
SELECT sum(length(rawJSON))                      FROM messageBody;  -- 4,785,035
SELECT sum(length(json_extract(rawJSON,'$.body'))) FROM messageBody;  -- 4,447,526
```

`body` is 93% of `rawJSON`, and it is a second copy of what `html` already holds. Every
message's text was on disk twice. Across the file that is **41% of the whole mirror**, and
it scales with exactly the thing ADR-0003 was already careful about.

`body` is also the one field in that payload that is neither unmodelled nor recovered from
anything: `MessageBody.body` is modelled, and the mapping writes it to `html` or
`plainBody` on the line above. Nothing can ever need the copy.

## Decision

`MirrorMapping.bodyWrite` removes the `body` key from the `/body` response before storing
it in `messageBody.rawJSON`. Every other field is kept, including the ones no Swift type
names.

The other three `rawJSON` columns are untouched. `account`, `mailbox` and `message` carry no
field large enough for this to matter — `message.rawJSON` is 162 KB across 155 rows, 1.0 KB
each, which is the price ADR-0020 was written to pay.

## Consequences

A mirror costs 41% less on disk for nothing given up. On the projected 50,000-message
mailbox in [local-mirror.md](../architecture/local-mirror.md#sizing-so-nobody-is-surprised)
that is gigabytes.

ADR-0020's promise now has one documented exception, and "everything the server sent" is no
longer literally true of `messageBody.rawJSON`. The exception is stated at the top of the
column's writer and here, and it is bounded: one named key, in one of four columns, whose
value is in the next column along.

A future feature that wants the server's pre-`?plain=true` body — the one from `/body`
rather than from `/html` — will not find it. The two differ only in the wrapper the server
puts around the fragment ([ADR-0009](0009-sanitised-html-not-raw-mime.md) and
[rendering.md](../architecture/rendering.md)), and the wrapper is machinery for an
`<iframe>` in a browser that this app does not use.

## Alternatives considered

**Keep it and compress `messageBody`.** Attacks the symptom, costs CPU on every read, and
the duplicate is still there when someone measures again.

**Drop `rawJSON` from `messageBody` entirely.** Tempting at 93%, and wrong: the other 7% is
`smime`, `phishingDetails`, `scheduling` and whatever Mail 5.13 adds, which is the case
ADR-0020 exists for. 337 KB across 155 messages, 2.2 KB each, is a fair price.

**Store `html` only in `rawJSON` and drop the column.** Inverts the problem: every render
would parse JSON to find its own body, and the FTS indexer along with it.

## Revisit when

Another payload grows a field the client both models and stores in its own column. The check
is a `dbstat` breakdown, not a reading of the code — this one was invisible until someone
divided the file size by the message count and did not like the answer.
