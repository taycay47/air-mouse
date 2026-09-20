# ADR-0004 — Accessibility state is advisory and must never gate input

**Status:** Accepted · 2026-08-31

## Context

The server reports whether the focused Mac element is a text field
(`focus_state`). It seemed reasonable to hold typed characters back when no text
field had focus, so text wouldn't vanish into nothing.

That was implemented — and **it broke typing completely.** `focus_state` is only
emitted after a *click*, so in normal use the flag sat `false` and swallowed
every keystroke, including backspace.

## Decision

`focus_state` is a **hint only**. It may change presentation (dimming the input
field) and must never gate, buffer, or delay sending.

More generally: **no Accessibility-derived state may sit on a critical path.**

## Why

The Accessibility API is unavailable or unreliable in a long tail of apps
(Electron needs `AXManualAccessibility`, Chrome's tree is lazy, canvas apps
expose nothing), and the permission can be revoked silently by an OS update.
Anything gated on it inherits that unreliability. A feature that degrades from
"polished" to "plain" when AX is unavailable is fine; one that degrades to
"broken" is not.

## Consequences

- Typed text is never discarded: it stays in the field until sent or cleared,
  and Send re-types it if the first attempt went nowhere.
- Backspace with the caret at position 0 is forwarded explicitly — the local
  field cannot shrink, so no `input` event fires, and without this you can only
  delete text you typed on the phone.
- ~~`focus_keyboard` is the one exception that consumes a user action (it
  swallows the next touch to open the keyboard). Precisely because of that, it
  is only sent on a genuine tap — never on drag-release or double-click, which
  made the trackpad feel broken.~~

  **Superseded by ADR-0008.** There is no exception: nothing may consume a
  user's touch on the strength of an Accessibility-derived message. Carving out
  `focus_keyboard` was a mistake, and the "only on a genuine tap" guard was not
  enough to make it safe — a tap that armed the flag with no second tap
  following left it primed to fire on whatever the user touched next, so the
  keyboard opened while they were moving the cursor. The keyboard is now opened
  by an explicit double-tap on the client, inside a real touch event.
