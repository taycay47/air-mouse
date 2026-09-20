# ADR-0003 — Pin the scene to the visual viewport instead of fighting iOS scroll

**Status:** Accepted · 2026-08-31

## Context

When the iOS keyboard opened, the entire UI — dot grid, background, controls —
was pushed upward, and the input bar either sat far above the keyboard or
vanished behind it entirely.

Root cause: iOS Safari does **not** resize the layout viewport for the keyboard.
It shrinks the *visual* viewport and scrolls the page to reveal the focused
field. `position: fixed` elements are anchored to the layout viewport, so they
travel with that scroll.

## Decisions

**1. The document is unscrollable.**
`html { overflow: hidden }`, `body { position: fixed; inset: 0 }`. With no
scrollable overflow, iOS has nothing to scroll and the scene cannot be pushed.

**2. A `#scene` wrapper tracks the visual viewport.** On every
`visualViewport` resize/scroll it is set to `translateY(offsetTop)` with
`height = vv.height`, so it always covers exactly the visible band.

**3. No CSS transition on the tracking.** `visualViewport` fires continuously
throughout the keyboard animation, so the bar already tracks it frame by frame.
A transition on top lags behind and reads as jumping.

**4. Canvas sizes from its own rect, not `window.innerHeight`.** On iOS those
differ; sizing the drawing buffer from `innerHeight` while the CSS box is
`clientHeight` scales the buffer and displaces every ripple from the finger.

## Rejected

- **`window.scrollTo(0,0)` to undo the shift.** Tried; it fights iOS every frame
  and produces exactly the jumping it was meant to fix. A band-aid on a
  structural problem.
- **A fixed pixel nudge.** Tried 40px; had literally zero effect, which is what
  finally revealed the transform wasn't the thing positioning the bar.
- **`interactive-widget=resizes-content`.** Correct in principle, unsupported by
  Safari.

## Notes

Painting *behind* the keyboard is impossible: iOS scrolls the document to its
bottom, so the last document pixel **is** the keyboard's top edge. The ambient
glow instead masks to transparent at that edge, so page black meets keyboard
black and no seam is visible. Measured `sceneOverhang` was always 0 — the
machinery that assumed otherwise was removed.

## Consequences

- Any new fixed-position UI must live inside `#scene`, or it will not track the
  keyboard.
- **`visualViewport` firing every frame cuts both ways.** Decision 3 relies on
  it: cheap work (a transform and a height) *should* run per frame. Expensive
  work must not. The dot grid was rebuilt from that same event — reallocating the
  canvas backing buffer and regenerating every dot — so toggling the keyboard ran
  dozens of full rebuilds back to back, starved the main thread, and made the
  trackpad stop responding mid-animation. Expensive listeners on this event need
  debouncing until the viewport settles; only the tracking transform belongs on
  the per-frame path.
- A native iOS client makes this entire ADR obsolete — real keyboard
  notifications, no viewport games.
