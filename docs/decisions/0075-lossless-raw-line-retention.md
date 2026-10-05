<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0075: vCard and iCalendar properties keep their unfolded original line, and an untouched property is re-emitted from it

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-17, while writing the `NCMailCore/Contacts` parser and serialiser

## Context

ADR-0069 commits v2 to a lossless vCard parser and serialiser of our own: a card another
CardDAV client wrote must survive our round trip with its `X-` properties, odd parameters
and group prefixes intact, because a sync client that rewrites what it does not understand
corrupts other people's data. WS-17's acceptance bar makes that measurable: parsing then
serialising each recorded vCard yields identical bytes, modulo line folding.

"Lossless" can be built two ways. A *model* round trip parses each line into
group/name/parameters/value and rebuilds the text from those parts; it is lossless only if
every quoting, escaping and case choice the original made is also captured and replayed.
The recorded cards already show where that breaks: sabre writes
`TEL;TYPE="voice,cell";VALUE=URI:…` (a quoted comma list), vCard 2.1 imports carry bare
`HOME` parameter tokens and quoted-printable soft breaks, and `X-CUSTOM-FLAG;X-PARAM=weird
value;TYPE=home:semi\;colon,comma\,escaped` mixes an unquoted space with escapes. Each is a
place where "parse, then rebuild" can emit a different but equivalent line — which is a
diff on the server, an ETag change, and noise in every other client's sync.

iCalendar (RFC 5545) shares the content-line grammar, and the iMIP builders edit one
ATTENDEE inside an otherwise untouched VEVENT, so the same question applies there.

## Decision

`DirectoryProperty` — the one content-line type both formats use — keeps `rawLine`, the
*unfolded* original line, next to its parsed `group`, `name`, `parameters` and `rawValue`.
The serialisers (`VCardSerializer`, `ICalendar.serialize`) emit `rawLine` verbatim for every
property that has one, re-folded at 75 octets; only properties this app created or edited
are built from parts.

"Edited" is enforced by the type, not by convention: assigning any parsed field drops
`rawLine` (`didSet`), and the setters (`setProperty`, `setParticipation`) build a fresh
property. An in-place edit therefore can never be silently discarded in favour of the
original text, and an untouched neighbour can never be rewritten.

Folding is the one thing not preserved: the original fold points are discarded at parse and
the serialiser folds at 75 octets on UTF-8 scalar boundaries. Line endings become CRLF.

## Consequences

- `VCardTests.roundTripsEveryRecordedVCard` and
  `ICalendarTests.roundTripsEveryRecordedCalendarObject` sweep the fixture directory, so
  every newly recorded card or calendar object is covered by the byte-identity bar without
  anyone adding a test; `DAVClientTests.addressbookMultigetCarriesWholeVCards` applies the
  same bar to the cards the server serves inside a multiget.
- A parameter shape the parser half-understands cannot be destroyed, because the parsed
  parts never feed back into an untouched line. Parser bugs degrade typed accessors, not
  data.
- Memory: each property holds its text roughly twice (raw line plus parsed parts). Cards
  are small and parsed on demand; the mirror stores the vCard bytes, not this model.
- Editing one property changes exactly one logical line, which keeps server-side diffs and
  other clients' syncs quiet (`editingOnePropertyLeavesEveryOtherByteAlone`).

## Alternatives considered

**Model round trip with captured quoting/case/escape choices.** Possible, but every
captured choice is another field the serialiser must replay correctly, and the failure mode
is silent rewriting of other clients' data. Keeping the line is simpler and strictly safer.

**Preserve original folding too.** Folding is transport detail (RFC 6350 §3.2) and sabre
re-folds on write anyway; keeping fold points would mean holding physical lines and
deciding what to do when one of them is edited, for no observable gain. The acceptance bar
is explicitly "modulo line folding".

**`CNContactVCardSerialization`.** Rejected in ADR-0069: it drops `X-` properties.

## Revisit when

A property this app edits needs to keep its original parameter spelling while changing its
value (today an edit rebuilds the whole line from parts), or a consumer needs the original
fold points.
