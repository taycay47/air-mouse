# ADR-0008 — The phone keyboard opens on double-tap, not by arming a flag

**Status:** Accepted · 2026-09-01 · supersedes part of ADR-0004

## Context

iOS Safari will not let `textInput.focus()` succeed from a WebSocket message
handler — opening the keyboard requires a real user gesture.

The original workaround: on `focus_keyboard`, set a flag; the next `touchstart`
sees the flag, calls `focus()`, and returns without acting on the trackpad. The
touch is spent opening the keyboard.

It never worked properly, in both directions at once:

- **The keyboard didn't open when asked.** `focus_keyboard` arrives ~200ms after
  the tap (a deliberate delay, so the Accessibility tree has settled). The second
  tap of a double-tap starts 150–250ms after the first — usually *before* the
  flag is armed. So the double-tap found nothing and did nothing.
- **The keyboard opened when not asked.** Once armed there was no way to
  un-arm it: the protocol has no cancel, and the server cannot know whether the
  user is still interested. After a lone tap the flag sat there and fired on the
  next touch, whenever that came — so the keyboard sprang open while the user was
  moving the cursor.

Tuning the delay only traded one failure for the other, because the two windows
overlap. The mechanism was structurally a race across the network.

## Decision

The client opens the keyboard itself, on an explicit **double-tap**, from inside
the `touchend` handler — which *is* a user gesture, so iOS permits it.

`focus_keyboard` and `focus_state` are demoted to what everything else
Accessibility-derived already is: hints. Neither may consume a touch.

## Why the client

The decision needs two facts at once: that the user just double-tapped, and that
the Mac's focused element is a text field. Only the client knows the first, and
it already receives the second. Deciding there removes the round trip from the
critical path entirely — there is no window to lose.

## Consequences

- No touch is ever swallowed, so there is no way for the keyboard to appear at a
  moment the user did not ask for it.
- Degrades correctly: if `focus_state` never arrives (AX unavailable, permission
  revoked, an Electron app), the double-tap still reaches the Mac as a
  double-click and only the keyboard convenience is lost — consistent with
  ADR-0004's rule that AX may take a feature from "polished" to "plain", never to
  "broken".
- The double-tap also still selects the word under the cursor, being a real
  double-click. If that turns out to be annoying while typing, suppressing
  `double_tap` when the target is a text field is the obvious follow-up.
- `focus_keyboard` stays in the protocol. It is still the only signal that says
  "a text field just took focus", which a future native client — with real
  keyboard APIs and no gesture restriction — can use directly.
