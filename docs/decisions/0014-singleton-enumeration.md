# ADR-0014: Enumerate with `view=singleton`; thread locally

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Architecture, from reading `MessageMapper::findIdsByQuery`

## Context

`GET /api/messages` takes `view=threaded` or `view=singleton`. The names suggest a display
preference. They are not: the threaded view joins the message table to itself on
`thread_root_id` and keeps only rows with no newer sibling
(`lib/Db/MessageMapper.php::findIdsByQuery`). It returns **one message per thread**.

A client that enumerates a mailbox with `view=threaded` therefore mirrors thread heads and
silently misses every reply — and misses them in a way no error reports and no count
reveals, because the mailbox's `stats` total counts messages while the enumeration counted
threads.

The same trap sits in the sync endpoint: `findNewIds` applies the identical self-join, so
`newMessages` only ever names thread heads
([ADR-0015](0015-bounded-sync-window.md)).

## Decision

**Every enumeration uses `view=singleton`.** Threading is computed locally from the
`threadRootId` the server already puts on every envelope.

The list's threaded display is then a local query:

```sql
SELECT * FROM message m
WHERE m.mailboxId = ?
  AND m.sentAt = (SELECT max(sentAt) FROM message
                   WHERE mailboxId = m.mailboxId AND threadRootId = m.threadRootId)
ORDER BY m.sentAt DESC
```

with the thread's message count and unread count alongside it.

## Consequences

- The mirror is complete, which is the entire premise of [ADR-0003](0003-local-first-full-mirror.md).
- Switching between threaded and flat is instant and offline: it is a different query over
  the same rows, not a different request.
- Thread grouping matches the server's, because we use the server's `threadRootId` rather
  than re-deriving it from `References` and `In-Reply-To`.
- The threaded query must be indexed properly — `idxMessageThread` on
  `(mailboxId, threadRootId, sentAt DESC)` — or it becomes the slowest thing in the app.
  WS-08 benchmarks it on 50,000 rows.
- A message whose thread spans mailboxes threads per mailbox, which is what the web client
  does too.

## Alternatives considered

**Enumerate threaded, fetch siblings per thread.** One request per thread on top of the
pages. Slower, heavier on the server, and the sibling endpoint (`/thread`) returns what is
already local once the mirror is complete.

**Derive threads locally from `References`/`In-Reply-To`.** Full control and guaranteed
divergence from the web client's grouping — the same conversation grouped two ways in two
clients is a bug report waiting to happen.

## Revisit when

The server gains a bulk enumeration endpoint, or `threadRootId` stops being reliable.
