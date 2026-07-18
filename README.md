# Air Mouse

Turns your phone into a trackpad / air mouse for your Mac. A Python server on
the Mac accepts a WebSocket connection from a phone's browser and injects the
resulting mouse, keyboard, and scroll events via CoreGraphics.

## Components

- **`mouse_controller.py`** — the server. Serves the web client over HTTPS and
  accepts control messages over a WebSocket on the same port (default 8443),
  translating them into real mouse/keyboard events via CoreGraphics.
- **`web/`** — the mobile web client (trackpad + air-mouse/gyro modes,
  scrolling, keyboard, dictation, macOS Zoom controls, keyboard shortcuts).
- **`menubar/`** — a native Swift menu bar app that starts/stops the server and
  shows the pairing QR code and PIN from a menu bar popover. Currently wraps
  the existing Python server rather than reimplementing input injection
  natively — see [`menubar/README.md`](menubar/README.md).
- **`air-mouse/`** — a Raycast extension that does the same start/stop/QR job
  as the menu bar app, for people who prefer Raycast.
- **`osc_receiver.py`** — a standalone OSC telemetry receiver, useful for
  debugging phone sensor apps independently of the main server.

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Run the server:

```bash
python3 mouse_controller.py
```

On first run it generates a self-signed TLS certificate (`cert.pem`/`key.pem`,
regenerated automatically if it's missing or about to expire) and prints a
QR code plus a 6-digit **pairing PIN**.

The Mac needs **Accessibility** permission granted (System Settings → Privacy
& Security → Accessibility) to whichever process runs the server — Terminal,
the venv's `python3`, or `AirMouseBar.app`, depending on how you launch it.
`switch_desktop` (Mission Control) and Zoom shortcuts additionally need
**Automation** permission for "System Events".

## Connecting a phone

1. Make sure the phone is on the same network as the Mac (or reachable via
   Tailscale — the Raycast extension lists that option too).
2. Open the printed URL (or scan the QR code) in Safari. iOS requires HTTPS
   for motion sensor access, so the self-signed cert warning is expected —
   tap **Show Details → visit this website**.
3. Enter the PIN shown in the terminal (or the menu bar app / Raycast
   extension). This only needs to happen once per device — the phone stores a
   session token and reconnects automatically after that, even across server
   restarts.

## Security model

Every WebSocket connection starts unauthenticated; the server ignores all
control messages until the client sends the correct pairing PIN (or a
previously-issued session token). Wrong-PIN attempts are rate-limited across
all connections. Paired device tokens are stored in `paired_devices.json`
(gitignored, `chmod 600`) — delete it to force every device to re-pair.

This is meant for trusted local networks, not adversarial ones: the PIN is a
deterrent against casual/opportunistic connections from other devices on the
same Wi-Fi, not a substitute for network-level trust.
