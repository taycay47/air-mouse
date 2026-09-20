# Air Mouse wire protocol

The phone client and the Mac server talk JSON over a single WebSocket, on the
same TLS port that serves the web client (default 8443).

This document is the **specification**. When the server is ported to Swift, this
is the contract the port must satisfy — not `mouse_controller.py`'s current
implementation details. Where the two disagree, fix whichever is wrong, but
decide deliberately.

Every message is a JSON object with a `type` field. Unknown `type` values must be
ignored, not treated as errors — this is what allows one side to ship a new
message before the other understands it.

---

## Connection lifecycle

```
phone                                    mac
  │                                       │
  ├─── WSS connect ──────────────────────▶│
  │                                       │
  ├─── {type:"auth", token|pin} ─────────▶│
  │                                       │
  │◀── {type:"auth_ok", token} ───────────┤   store token, persist
  │    or {type:"auth_fail", reason?} ────┤   show PIN entry
  │                                       │
  ├─── control messages ─────────────────▶│   (only after auth_ok)
  │◀── state messages ────────────────────┤
```

**Every control message before `auth_ok` must be dropped by the server.** The
client is not trusted to enforce this.

---

## Authentication

### `auth` — client → server

```json
{ "type": "auth", "token": "<hex>" }
{ "type": "auth", "pin": "123456" }
```

Exactly one of `token` or `pin`. The client sends `token` if it has one in
`localStorage`, otherwise it shows the PIN overlay and sends `pin`.

- `pin` — the 6-digit pairing PIN, **regenerated on every server start** and
  printed to the log / shown in the menu bar app.
- `token` — issued by a previous successful pairing, persisted server-side in
  `paired_devices.json`.

### `auth_ok` — server → client

```json
{ "type": "auth_ok", "token": "<hex>" }
```

Sent on success. The client persists `token` and reconnects with it thereafter,
skipping PIN entry. A token is issued for **both** PIN and token auth, so tokens
can be rotated.

### `auth_fail` — server → client

```json
{ "type": "auth_fail" }
{ "type": "auth_fail", "reason": "rate_limited" }
```

`reason` is currently only `rate_limited`. Failed attempts are rate limited
globally (not per-connection) — see `_AUTH_MAX_FAILS` / `_AUTH_WINDOW_SECONDS`.

> **Port note:** rate limiting is global process state today. Keep it global —
> per-connection limiting is trivially defeated by reconnecting.

---

## Control messages (client → server)

### `trackpad` — relative cursor movement

```json
{ "type": "trackpad", "dx": 12.4, "dy": -3.1 }
```

Deltas in points, **already scaled and accelerated by the client**. The server
applies them to the current cursor position and clamps to the virtual desktop
bounds. The server must not apply its own acceleration curve.

### `motion` — gyro / air-mouse movement

```json
{ "type": "motion", "rx": 0.8, "ry": -0.2, "rz": 0.1,
  "is_landscape": false, "sign_x": 1.0, "sign_y": 1.0 }
```

Angular deltas, client-scaled by the sensitivity setting. `is_landscape` and the
`sign_*` fields let the client tell the server how to map device axes to screen
axes without the server knowing about device orientation.

### `scroll`

```json
{ "type": "scroll", "dx": 0.0, "dy": 18.5 }
```

Scroll deltas. Sign convention follows the client's "invert scroll" setting —
the server scrolls exactly what it is told.

### `click`

```json
{ "type": "click", "button": "left|right", "action": "tap|down|up|double_tap" }
```

| action | meaning |
| --- | --- |
| `tap` | press and release |
| `down` | press and hold — begins a drag |
| `up` | release a held button |
| `double_tap` | two-click sequence (`click_count = 2`) |

**`down` must always be matched by an `up`.** If the connection drops while a
button is held, the server must release it — a stuck left button drags across
everything the cursor touches. See ADR-0006.

Side effects:
- `left`/`tap` → server checks focus and emits `focus_state` (+ `focus_keyboard`)
- `left`/`up` **following a `down`** → server emits `context` (drag-release is
  how text gets selected)
- `left`/`double_tap` → server emits `context` (double-click selects a word)

### `key` — a single keystroke, optionally with modifiers

```json
{ "type": "key", "code": "c", "modifiers": ["cmd"] }
{ "type": "key", "code": "backspace" }
```

`code` is a logical name resolved against the server's `KEY_CODES` table
(`enter`, `backspace`, `escape`, `tab`, `space`, letters, …). Unknown codes are
ignored. `modifiers` is any of `cmd`, `shift`, `alt`, `ctrl`.

Side effect: `⌘C`/`⌘X`/`⌘V`/`⌘A` re-check and emit `context`.

### `keyboard` — literal text

```json
{ "type": "keyboard", "text": "hello" }
```

Typed verbatim as Unicode. This is the path used by live passthrough and
dictation. Deletion is **not** expressed here — the client sends explicit
`{type:"key", code:"backspace"}` messages.

### `switch_desktop`

```json
{ "type": "switch_desktop", "direction": "left|right" }
```

> **Port note:** implemented via `osascript` + System Events, *not* CGEvent.
> Mission Control silently drops synthetic modifier flags from a non-HID source,
> so `Control+Arrow` posted via `CGEventPost` does nothing. This is a real
> platform quirk — keep the AppleScript path in the Swift port, or verify very
> carefully that a native alternative actually works. Requires the Automation
> permission, separately from Accessibility.

### `calibrate`

```json
{ "type": "calibrate" }
```

Resets the gyro baseline. No response.

---

## State messages (server → client)

These are **advisory**. The client must remain fully functional if they never
arrive — every one of them depends on the Accessibility API, which is
unavailable in some apps and can be revoked at any time.

### `focus_state`

```json
{ "type": "focus_state", "focused": true }
```

Whether the focused Mac element is a text field (`AXTextField`, `AXTextArea`,
`AXSearchField`, `AXSecureTextField`, `AXComboBox`).

**This must never gate sending.** It is a hint used to dim the phone's input
field. See ADR-0004 — gating on it once broke typing entirely.

### `focus_keyboard`

```json
{ "type": "focus_keyboard" }
```

"A Mac text field just took focus." A **hint**, nothing more — same rules as
`focus_state`.

A client must not consume a user's touch on the strength of this message. iOS
Safari will not open the keyboard from a WebSocket handler (it is not a user
gesture), so a client can only open the keyboard from inside a real touch
event; this message just tells it that doing so would be useful.

> **This message used to mean "arm the keyboard: swallow the next touch to open
> it."** That did not work, and the approach was removed — see ADR-0008. It
> raced the network (the message lands ~200ms after the tap, typically *after*
> the second tap of a double-tap has already started) and, once armed, the
> server had no way to take it back, so it fired on some later unrelated touch
> and the keyboard appeared while the user was moving the cursor.
>
> The web client now opens the keyboard on an explicit double-tap, inside the
> `touchend` gesture, using this and `focus_state` only as hints.

### `context`

```json
{ "type": "context", "hasSelection": true, "hasClipboard": true }
```

Drives the Copy / Paste pills.

- `hasSelection` — focused element has a non-empty `AXSelectedText`
- `hasClipboard` — pasteboard holds non-empty text

Emitted after: a tap, a drag-release, a double-click, and ⌘C/⌘X/⌘V/⌘A.
Never polled — see ADR-0005.

Unknown state is reported as `false`, never omitted. See ADR-0005 on fail-closed.

---

## Static file serving

The same TLS listener serves the web client over HTTPS. Requests that carry an
`Upgrade: websocket` header become WebSocket connections; everything else is a
file read from `web/`.

- `/` → `/index.html`
- Paths are resolved against `web/` and **must** be verified to stay inside it
  after `realpath` — prefix matching alone is not sufficient (a sibling such as
  `web-private` shares the prefix).
- `Cache-Control: no-store` on everything, so a reload always gets fresh code.

> **Port note:** once a native iOS client bundles its own assets, this exists
> only for the browser/PWA path. Don't over-build it.

---

## Invariants worth preserving

1. **Client owns feel, server owns injection.** All acceleration, smoothing,
   momentum, and gesture recognition live in the client. The server translates
   messages into events and does no interpretation. This is what lets the web
   and native clients feel identical without duplicating tuning.
2. **Unknown message types are ignored, both directions.**
3. **Advisory state is never required.** The client works with zero state
   messages; they only add polish.
4. **Held buttons are always released** — on disconnect, on error, on exit.
5. **No control message is honoured before `auth_ok`.**
