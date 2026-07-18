# AirMouseBar

A native macOS menu bar app for Air Mouse. Click the icon in the menu bar to
start/stop the server and see the pairing QR code and PIN.

## What this is (and isn't) v1

This is a **wrapper**, not a rewrite: it manages `mouse_controller.py` as a
child process and gives it a proper menu bar UI (status, QR code generated
natively via CoreImage, PIN, start/stop). Mouse/keyboard injection still
happens in the Python/CoreGraphics server, not in Swift.

The natural next step is porting the CoreGraphics event-posting logic
(`mouse_controller.py`'s `post_mouse_event`/`press_key`/`type_string`, etc.)
directly into Swift, dropping the Python dependency entirely. That's a bigger
project and deliberately out of scope here — this app exists to fix the
distribution/UX problem (a Raycast extension can't ship a Python runtime, and
users need a real onboarding/permissions flow) without blocking on that
rewrite.

## Building

```bash
./build_app.sh          # debug build -> AirMouseBar.app
./build_app.sh release   # release build
```

Then `open AirMouseBar.app`, or move it to `/Applications`.

It resolves the repo root (and therefore `.venv/bin/python3` and
`mouse_controller.py`) relative to its own source location at compile time —
it does not need to be told where the repo lives, as long as `menubar/` stays
inside the same checkout.

## Permissions

Same as running the server any other way: grant **Accessibility** to
whichever binary actually posts the events. Since this app spawns Python as a
child process, that means granting Accessibility to `.venv/bin/python3` (not
to `AirMouseBar.app` itself) — check System Settings → Privacy & Security →
Accessibility if input doesn't seem to reach the Mac.
