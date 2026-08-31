# ADR-0007 — Vendor Motion locally; drop GSAP

**Status:** Accepted · 2026-08-31

## Context

UI animation needed spring physics to match the Apple-like feel. GSAP was loaded
from cdnjs — two `<script>` tags — and used for exactly one thing:
`gsap.ticker.add()`, a `requestAnimationFrame` loop.

## Decision

- Vendor Motion (`motion@13.1.1`, UMD) into `web/vendor/motion.js`, served by
  our own server.
- Remove both GSAP scripts; replace the ticker with plain `requestAnimationFrame`.

## Why

**Vendored, not CDN:** the app is heading toward offline support and native
packaging. A third-party CDN means the client cannot load without internet even
when the Mac is reachable — the exact failure the offline work is meant to
eliminate.

**Net fewer remote dependencies:** two CDN scripts → zero. Adding an animation
library actually *reduced* external dependencies, because GSAP was 70 KB of CDN
fetch for a `rAF` wrapper.

## Consequences

- `web/vendor/motion.js` is committed (~140 KB). Vendored dependencies need
  manual updating; pin the version and note it here when bumped.
- Motion is available globally for the settings sheet, toasts, and the send
  button, which are still on CSS transitions.
- **Never animate the same property in both CSS and Motion.** A leftover
  `transition` on `opacity`/`transform` makes the browser re-animate every frame
  Motion writes and turns springs to mush. The context pills hit this.
