<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0107: The message web view strips the context-menu items that start a load

**Status:** Accepted
**Date:** 2026-10-08
**Decided by:** the security audit of 2026-10, which sent a GET to a sender's host from
WebKit's **Download Linked File**, with no link confirmation and the content rule list
installed

## Context

The body's protections assume every load goes through one of two places: the navigation
delegate, which cancels it and runs the link confirmation, or the content rule list, which
blocks everything but `ncmail:`
([security.md](../architecture/security.md), "Malicious message content"). WebKit's stock
context menu breaks that assumption. **Download Linked File** (and **Download Image**,
**Download Media**) starts a download inside WebKit that reaches neither delegate method
and that the rule list does not see. The audit observed one unauthenticated GET to the
sender's chosen host, carrying the user's IP and a per-recipient token. The **Open … in New
Window** items do reach `createWebViewWith`, which declines them, but they are no use in a
view that never opens a window.

The `WKMenuItemIdentifier…` constants that name these items are exported by WebKit but
declared in no public header.

## Decision

- The message body is a `MessageBodyWKWebView`, a `WKWebView` subclass that overrides
  `willOpenMenu(_:with:)` and removes, by identifier, Download Linked File, Download Image,
  Download Media, and Open Link / Image / Media / Frame in New Window. Separators the
  removal strands are removed with them.
- The identifiers are spelled as their string values. They are the strings the menu items
  carry, and the audit's harness matched the live menu with them on macOS 26.
- Open Link and Copy Link stay. Open Link arrives as an ordinary link activation and goes
  through the confirmation. Everything else WebKit or the system adds (Copy, Look Up,
  Share…) stays: none of it starts a load in the web view.
- The offscreen print web view keeps the plain `WKWebView`. It is never on screen, so it
  never shows a menu.

## Consequences

- No context-menu path reaches the sender's host. The rule list and the confirmation cover
  every load again.
- The reader cannot download a linked file from a message. Open Link hands it to the
  browser, which can.
- A blocklist misses an item WebKit adds later that also loads. The full set of identifiers
  WebKit exports on macOS 26 was read from its `.tbd`; these seven are the ones that load.
  A string WebKit renames is no longer removed, and nothing fails to say so.

## Alternatives considered

**Keep only an allowlist of items.** It would remove a future loading item by default,
but also every harmless item the system adds later (Writing Tools, Translate), with
nothing to say a feature had gone. The loading items are a short, named set.

**A download delegate that cancels every download.** Covers Download Linked File without
touching the menu, but the menu would still offer an item that silently does nothing.

**Turn the context menu off.** Loses Copy, Copy Link and Look Up, which readers use.

## Revisit when

WebKit publishes the menu identifiers, or adds a context-menu item that loads, or offers a
configuration switch that keeps downloads and new windows out of a web view.
