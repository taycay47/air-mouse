# AirMouseBar

A native macOS menu bar app for Air Mouse. Click the icon in the menu bar for a
small glass panel: a switch for the server, the pairing code, and a QR code for
pairing a browser. Everything rarer — updates, setup, uninstall, quit — sits
behind the ⋯ button.

## What this is

The whole thing, in Swift. There is no Python involved at runtime: input
injection, the Accessibility layer, TLS, WebSocket, static file serving and
pairing all run **in-process** inside this app. See
`docs/adr/0002-port-input-injection-from-python-to-swift.md`.

`mouse_controller.py` is still in the repo as the reference implementation, and
`docs/PROTOCOL.md` remains the specification both sides are written against.

## Targets

| Target | Kind | What it's for |
| --- | --- | --- |
| `AirMouseBar` | executable | The app. Menu bar UI + the server, in one process. |
| `AirMouseServerCore` | library | TLS + WebSocket + HTTP + pairing. |
| `AirMouseCore` | library | CGEvent injection and the Accessibility layer. |
| `AirMouseInjector` | executable | Dev tool: reads JSON messages from stdin and injects them. Useful for testing injection without a phone. |
| `AirMouseServer` | executable | Dev tool: runs the server standalone in a terminal, where its log output is visible. |

The two dev tools are not part of the shipped app. They are separate binaries,
so macOS treats them as separate applications for permissions — if you use them,
they need their own Accessibility grant (see below).

## Building

```bash
swift build              # all targets
./build_app.sh           # debug build -> AirMouseBar.app
./build_app.sh release   # release build
```

Then `open AirMouseBar.app`, or move it to `/Applications`.

It resolves the repo root (and therefore `web/`) relative to its own source
location at compile time, so it does not need to be told where the repo lives —
as long as `menubar/` stays inside the same checkout. Making the bundle properly
self-contained is step 2 of `docs/ROADMAP.md`.

## Permissions

Grant **Accessibility** to `AirMouseBar` itself — it is the process that posts
the events now, so there is nothing hidden to hunt down in a file picker. That
was a large part of the point of the port.

Two things worth knowing if input or the Copy/Paste pills stop working:

- **A rebuild can invalidate the grant.** SwiftPM ad-hoc-signs each build, and
  macOS keys the grant to the signature. Re-toggling the entry in System Settings
  → Privacy & Security → Accessibility fixes it.
- **`CGEventPost` and the Accessibility API do not fail together.** Cursor
  movement can keep working while `AXUIElementCopyAttributeValue` returns
  `kAXErrorCannotComplete`, which looks like an AX bug but means the grant isn't
  really there for the process doing the asking.

`switch_desktop` additionally needs **Automation** (System Events), requested
the first time it is used — it goes through AppleScript because Mission Control
ignores synthetic modifier flags from `CGEventPost`.

## Testing a cold install

`./reset_install.sh` removes every trace of Air Mouse from the Mac — the
bundle, the generated certificate and pairing tokens, preferences, caches, and
the TCC Accessibility and Automation grants — so the next install from the
`.dmg` exercises the real first-run path.

    ./reset_install.sh --dry-run    # show what would go, change nothing
    ./reset_install.sh              # confirm, then remove
    ./reset_install.sh --yes        # no prompt

Dragging the app to the Trash is not equivalent. The Accessibility grant lives
in TCC rather than in the bundle, preferences are cached by `cfprefsd` and get
written back out after the plist is deleted, and `paired_devices.json` lets the
phone skip PIN entry — so pairing appears to work without having been tested.

The phone holds state the Mac cannot clear: delete the Home Screen icon and
clear Safari's website data for the Mac's hostname, which is what drops the
saved token and the accepted certificate exception.
