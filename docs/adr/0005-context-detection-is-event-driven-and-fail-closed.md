# ADR-0005 — Selection/clipboard detection is event-driven and fail-closed

**Status:** Accepted · 2026-08-31

## Context

Contextual Copy/Paste pills need to know whether the Mac has selected text and
whether the clipboard holds anything.

## Decisions

**1. Event-driven, never polled.** The check runs after the gestures that can
change the answer: a tap, a drag-release, a double-click, and ⌘C/⌘X/⌘V/⌘A.

The phone already knows when a selection likely happened — **dragging is the
text-selection gesture**. Polling would be both wasteful and risky: AX reads can
block for hundreds of milliseconds in Electron apps, which on a 300 ms timer
would cause visible hitches in the cursor.

**2. Fail-closed.** Unknown state is reported as `false`. A missing Copy pill is
a non-event; a Copy pill that appears when nothing is selected is worse than no
feature at all.

**3. The clipboard probe is cached** (3 s TTL, force-refreshed after ⌘C/⌘X).
The check shares a code path with the per-tap focus check, so an uncached
`pbpaste` would spawn a subprocess on **every tap**, adding latency to the click
path.

## Reliability, honestly

| Context | Works |
| --- | --- |
| Native Cocoa (Notes, Mail, TextEdit, Xcode, Terminal) | Reliably |
| Safari | Generally |
| Chrome | Usually — lazy AX tree |
| Electron (VS Code, Slack, Discord) | Often needs `AXManualAccessibility` |
| Finder selection, canvas apps | No — not *text* selection |

Reliable where people actually select text; unreliable in a long tail. That is
acceptable precisely *because* of the fail-closed rule.

## Consequences

- The pills are a progressive enhancement. ⌘C/⌘V remain in the shortcuts grid.
- Adding a new selection-changing gesture means adding a trigger; there is no
  poll to catch it automatically. This is the intended trade.
