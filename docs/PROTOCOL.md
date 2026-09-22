# Air Mouse wire protocol

The phone client and the Mac server talk JSON over a single WebSocket, on the
same TLS port that serves the web client (default 8443).

This document is the **specification**. When the server is ported to Swift, this
is the contract the port must satisfy — not `mouse_controller.py`'s current
implementation details. Where the two disagree, fix whichever is wrong, but
decide deliberately.

**Messages are sent as WebSocket _text_ frames**, in both directions. Binary
frames are ignored by the server — silently, with no error and no close — so a
client that sends them sees a connection that opens, accepts everything, and
answers nothing. That is indistinguishable from an unreachable Mac, and it cost
a long debugging session when the native client sent binary by default.

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

```json
{ "type": "scroll", "dx": 0.0, "dy": 2.4, "modifiers": ["cmd"] }
```

Scroll deltas. Sign convention follows the client's "invert scroll" setting —
the server scrolls exactly what it is told.

`modifiers` is optional and takes the same values as `key`. Its purpose is
zoom: Figma, Canva, browsers and most creative tools map ⌘-scroll to canvas
zoom, and that is the same path their own pinch-to-zoom takes. Posting a real
`NSEventTypeMagnify` is not possible with public API, so a pinch on the phone
reaches them as ⌘-scroll.

An unrecognised modifier invalidates the whole message, for the same reason it
does on `key`: a zoom that silently arrives as a scroll is doing something
different from what was asked.

The values are in *line* units, which is what the client's curves were tuned
against. The server converts them to pixels with a constant factor before
posting (`AIRMOUSE_SCROLL_SCALE`, default 10) so it can send trackpad-class
continuous scroll events rather than notched wheel ones. That is a unit
conversion, not a curve — invariant 1 still holds, and the shape of the motion
is entirely the client's.

There is no scroll *phase* on the wire yet. Without one the server cannot mark
a gesture as begun/changed/ended, so macOS will not rubber-band at a document's
edges and cannot run momentum itself — the client synthesises its own and
streams it as ordinary `scroll` messages.

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

A second group of codes is not a keycode at all and takes its own route into
macOS (`SystemKeys.swift`), but travels as an ordinary `key` message so the wire
format stays one shape:

| code | how it is sent | modifiers |
|---|---|---|
| `playpause`, `nexttrack`, `previoustrack` | `NX_SYSDEFINED` event, subtype 8 | ignored |
| `mute`, `volumeup`, `volumedown` | `NX_SYSDEFINED` event, subtype 8 | ignored |
| `missioncontrol` | System Events, `⌃↑` | ignored |
| `appexpose` | System Events, `⌃↓` | ignored |

`missioncontrol` needs the Automation permission, for the same reason
`switch_desktop` does: Mission Control drops synthetic modifier flags from a
non-HID source.

Brightness and dictation are deliberately absent. Brightness no longer responds
to `NX_KEYTYPE_BRIGHTNESS` from a synthetic event, and dictation is bound to a
double-press of a modifier rather than to a keystroke; neither can be sent
honestly, so neither has a code.

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

Sent by a three-finger swipe. As on a trackpad the desktops follow the fingers,
so swiping *left* sends `right`: the desktop on the right slides in. (It was
once a one-finger swipe from the left edge of the phone, which fired whenever
someone reached for that side of the screen to move the cursor.)

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

### `ping` — round-trip probe

```json
{ "type": "ping", "id": 7 }
```

Answered with `pong` carrying the same `id`, **on the channel the ping arrived
by**. That is the whole point of it: a ping sent over UDP and answered over TCP
would measure neither.

Answered before anything else in the handler and never passed to the injector,
so the measurement is of the network rather than of the server's own queueing.
`id` is opaque to the server.

---

## Channels

There are two ways into the server, and a client may use both at once.

**Reliable — TLS/WebSocket over TCP, port 8443.** Everything begins here:
authentication, keystrokes, clicks, every state message. This is the only
channel the web client has, and a native client that uses nothing else is fully
functional.

**Fast — DTLS over UDP, ephemeral port.** Offered by the server after `auth_ok`
(see `fast_channel`). Carries `trackpad`, `scroll` and `motion` only.

The split exists because TCP's guarantee is wrong for movement. A delta that
arrives 150ms late is worse than one that never arrives — the cursor freezes and
then jumps — and on a congested access point a single lost packet stalls
everything behind it until the retransmit lands. Over UDP a lost delta is lost,
and the next one corrects the small error it left.

**There are no sequence numbers, deliberately.** Deltas add, and addition
commutes, so movement packets arriving out of order produce the same cursor
position as in-order ones. Only loss matters, and loss is what this channel
chooses to accept.

Rules:

- Anything unrepeatable — clicks, keys, text, auth — stays on the reliable
  channel. A dropped delta costs a few pixels; a dropped click costs a click.
- **While a mouse button is held, movement goes back to the reliable channel.**
  The two channels have independent latency, and a `click`/`down` that lands
  after the movement it was meant to precede starts a drag in the wrong place.
- A client must not send on the fast channel until a `ping` sent over it has
  been answered over it. A completed DTLS handshake means the port is open, not
  that packets are getting through.

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

### `permission`

```json
{ "type": "permission", "accessibility": true }
```

Whether the server currently holds the macOS Accessibility grant.

Sent once immediately after `auth_ok`, then again only when the value changes.
Polled server-side (2s) because macOS gives no notification when a grant is
revoked.

This one is advisory in the same sense as the others — a client that ignores it
behaves exactly as it did before — but it is the only state message that
reports a condition the user *must* act on. Losing the grant is otherwise
completely invisible from the phone: the socket stays up, pairing succeeds,
every control message is accepted and acknowledged, and the cursor does not
move. The client shows a banner naming the pane to re-enable it in.

Clients must treat a missing `accessibility` field as `true`, so that a server
too old to send this message is not reported as broken.

### `pong`

```json
{ "type": "pong", "id": 7 }
```

The answer to a `ping`, echoing its `id`, sent on the channel the ping arrived
by.

### `fast_channel`

```json
{
  "type": "fast_channel",
  "port": 51234,
  "key": "<base64, 32 bytes>",
  "identity": "<uuid>",
  "service": "airmouse-1a2b3c4d"
}
```

An offer of the DTLS/UDP channel. Sent once, immediately after `auth_ok`, and
only over the reliable connection — which by then has authenticated and had its
certificate pinned. That envelope is what makes handing a key over in plain JSON
sound.

- `key` and `identity` are the DTLS pre-shared key and its identity, fresh per
  session. **Completing the handshake is the authentication**: there is no
  second PIN, token or replay window.
- `port` and `service` are two routes to the same listener. Connecting by
  service lets the system choose the path, including a direct AWDL radio link
  that never touches the access point; connecting by port is what works when it
  cannot. A client should try the service first and fall back to the port.
- The listener and its key are torn down with the connection that offered them.

Advisory like everything else here: a client that ignores this message keeps
working exactly as before, which is what every client older than it does. If the
listener cannot be opened, the server sends nothing and says nothing.

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
