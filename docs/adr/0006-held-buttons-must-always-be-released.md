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
- **client-side `touchcancel`** (added 2026-09-01 — see below)
- **on a newly authenticated connection**, since a button still held from a
  previous one is stale by definition

## The path this ADR missed

Every exit path listed originally was server-side, and all of them assume the
*connection* is what breaks. The failure that actually showed up in use had a
healthy connection throughout: **iOS cancels touches.**

When the keyboard animates in, a system edge-swipe starts, or a notification
arrives, iOS fires `touchcancel` instead of `touchend`. The web client only sent
`click/up` from `touchend`, so the `up` was simply never sent. The connection
stayed up, the server was working correctly, and the Mac was left with the button
held — dragging everything the cursor touched, exactly the symptom described
above. It correlated with toggling the keyboard, which made it look like a
keyboard bug.

The lesson generalises: "release on every exit path" has to include the paths
where the *gesture* is interrupted, not just the ones where the transport is.
A held button is client state as much as server state, and the client has exit
paths of its own (`touchcancel`, backgrounding) that no server-side handler can
see.

## Why the second one

A per-connection handler covers the common case but not the one that leaves the
Mac in a broken state after the app is gone. `atexit` is a cheap backstop for an
expensive failure.

## Consequences

- The Swift port must reproduce **both** paths, including signal handling —
  `atexit` semantics differ, and a `SIGTERM` from the menu bar app stopping the
  server is a realistic route to a stuck button. (Done: `SIGINT`/`SIGTERM`
  handlers plus `channelInactive` per connection.)
- The release-on-authenticate path covers the "connected but wedged" case that
  the watchdog idea below was aimed at, without having to guess a timeout that a
  legitimately slow drag would trip over. A watchdog is no longer planned.
- The server tracks the held button process-globally rather than per connection.
  This is deliberate: there is one physical mouse button, so whether to post
  `leftMouseDragged` or `mouseMoved` should reflect its real state, not one
  connection's opinion of it.
