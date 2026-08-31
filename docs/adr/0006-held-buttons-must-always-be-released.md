# ADR-0006 — A held mouse button must always be released

**Status:** Accepted · 2026-08-31

## Context

Drag is expressed as `click/down` … movement … `click/up`. If the `up` never
arrives — connection drop, client crash, server killed — the left button stays
logically held. The cursor then drags across everything it touches: text gets
selected, files get moved, UI gets dragged. The symptom is bizarre and gives no
hint of the cause.

## Decision

Release held buttons at every exit path:

- per-connection `finally` (normal disconnect or error)
- process `atexit` (the `finally` cannot run if the process dies)

## Why the second one

A per-connection handler covers the common case but not the one that leaves the
Mac in a broken state after the app is gone. `atexit` is a cheap backstop for an
expensive failure.

## Consequences

- The Swift port must reproduce **both** paths, including signal handling —
  `atexit` semantics differ, and a `SIGTERM` from the menu bar app stopping the
  server is a realistic route to a stuck button.
- Worth extending later: a watchdog that releases after N seconds with no
  messages, covering a client that is connected but wedged.
