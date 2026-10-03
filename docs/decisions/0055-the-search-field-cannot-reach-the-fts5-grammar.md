<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0055: The search field cannot reach the FTS5 grammar

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-11

## Context

FTS5's `MATCH` argument is a small language. It has `AND`, `OR`, `NOT` and `NEAR`, column
filters (`subject : hedgehog`), parentheses, quoted phrases and a prefix `*`. A mail search
field is not that language: somebody typing `NOT` is looking for the word "not", and
somebody typing `(` has made a typo.

Passing the field's contents through unchanged gives two failures, and the quiet one is
worse. `hedgehog NOT census` finds fewer messages than `hedgehog` and nobody can tell why.
`(hedgehog` throws a syntax error, which reaches the screen as an empty list with no
explanation, indistinguishable from "no such message".

Wrapping each word in an FTS5 string literal and doubling any quote inside it — the
textbook answer — fixes the operators and still has a hole. SQLite reads a `MATCH`
expression as a C string, so a NUL byte truncates it: `hedgehog` NUL `census` inside a
literal became an unterminated string and FTS5 rejected the query. A NUL cannot be typed,
but it can be pasted, and a fuzz over the punctuation found it on the first run.

## Decision

Reduce the input to what the tokeniser would have kept, and only then quote it.

`FTS5MatchExpression` splits the field on quotes and whitespace, drops every character that
`unicode61` treats as a separator — anything that is not a Unicode letter or number — and
joins what is left with single spaces. Each term becomes one quoted phrase; a bare word
gets `*` for prefix matching, a closed phrase does not, and the terms are joined with
`AND`. A term with no token characters is dropped, and an input with no terms left produces
no expression and therefore no results.

So the only characters that reach SQLite are letters, digits and spaces, and the only
grammar in the expression is the `*` and the `AND` this code put there.

## Consequences

- `NOT`, `-`, `*`, `(`, `NEAR(a b, 2)`, an emoji and `'; DROP TABLE message; --` are all
  ordinary text. Against the live server, `NOT` matches 78 of 156 messages, which is how
  many contain the word.
- There is no quote left to escape, because a quote is a delimiter before it is a
  character. The doubling in the renderer would be unreachable; the code does the reduction
  instead and the renderer has nothing left to do.
- Nothing the user types can be a syntax error. A 500-term paste is truncated to
  `maximumTerms` rather than thrown back, because search runs per keystroke and a paste is
  one keystroke.
- An empty or whitespace-only field matches nothing. The brief asks for that, and it falls
  out of the same rule rather than needing a special case.
- Punctuation inside a word behaves as it does in the index: `hedge-hog` becomes the phrase
  `hedge hog`, which is what FTS5 would have made of it anyway.
- The user cannot ask for a boolean query. That is deliberate for v1 — the brief puts
  filter-string syntax out of scope — and if it is ever wanted it goes in as a parser in
  this one file, not by letting the raw field through.

## Alternatives considered

**Quote and escape, without the reduction.** The usual advice, and it survives every
operator. It does not survive a pasted NUL, and the failure only shows on input nobody
would think to test.

**Strip the operators by name.** Removing the words `AND`, `OR`, `NOT`, `NEAR` from the
input means a search for "not" cannot be typed at all, and it leaves every punctuation mark
still live.

**Parse a real query syntax.** `from:sookie after:2024` is a good feature and a different
one. Out of scope for v1 ([WS-11's brief](../delivery/briefs/WS-11-search.md)), and it
would sit on top of this rather than replace it.
