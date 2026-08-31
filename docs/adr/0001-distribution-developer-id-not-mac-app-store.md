# ADR-0001 — Mac app ships as a notarized .dmg, not via the Mac App Store

**Status:** Accepted · 2026-08-31

## Context

The Mac side needs an install story for non-technical users: download, drag to
Applications, open. The App Store is the obvious default for that.

## Decision

Distribute the Mac app as a **Developer ID–signed, notarized `.dmg`**, downloaded
from the web. Do not target the Mac App Store.

## Why

App Store apps must be sandboxed, and the sandbox does not permit posting
synthetic global input events into other applications — which is the entire
purpose of this app. Every comparable tool (Karabiner-Elements, BetterTouchTool,
Hammerspoon) ships outside the App Store for the same reason.

This is not a preference. It is a capability limit, and no amount of entitlement
paperwork changes it.

## Consequences

- Requires an Apple Developer membership ($99/yr) for the Developer ID
  certificate and notarization. The same membership covers iOS App Store
  distribution for the planned phone client, so the cost is shared.
- The build must sign, notarize, and **staple** the ticket. An un-stapled app
  fails to launch for users who are offline on first run.
- Updates are self-hosted — no App Store update channel. Plan for Sparkle or an
  equivalent, or accept manual re-download.
- Precedent for the split model (iOS app on the App Store, Mac companion via
  direct download): Astropad, Duet Display. It passes review routinely.
