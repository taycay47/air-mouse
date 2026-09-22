# User onboarding

The target: **download, grant one permission, enter a pairing code.** Everything below
exists to protect that.

## Mac — first run (~60 seconds)

1. Download `.dmg` → drag to Applications → open.
2. A real window appears (not the menu bar popover — a popover is the wrong
   place for first-run).
3. Two steps, one sentence each. **Allow control** → one button →
   `AXIsProcessTrusted(prompt:)` → System Settings opens at the right pane.
   Restart and "not listed?" help appear only if the grant has not arrived
   after a few seconds.
4. The app **polls for the grant and advances by itself.**
5. **Pair your phone**: the server starts and the pairing code is shown large.
   Browser pairing (QR code, certificate note) is one link away, not on screen.

## Phone — first run (~30 seconds)

6. Camera → scan QR → Safari opens.
7. ⚠️ **"This Connection Is Not Private"** → Show Details → visit this website.
8. Page loads → enter the 6-digit PIN → paired, token stored.
9. **Prompt to Add to Home Screen**, with a picture of the Share icon.
10. Done.

## Daily use

Tap the home-screen icon. It reconnects with the stored token — no PIN, no QR.
The Mac app starts at login and the server is already running.

---

## The friction point

**Step 7 is the biggest risk to adoption.** A security warning, on the very first
interaction, immediately before granting something control of your computer, is
the worst possible moment for a scare.

Options, in increasing order of effort:

1. **Guide it well** — a dedicated step with screenshots. Sufficient for v1.
2. **A real certificate for a LAN address** — a public DNS record for
   `*.something.yourdomain` resolving to the private IP, with a genuine cert.
   Plex and Home Assistant both do this. Requires a domain, and the private key
   ships inside the app.
3. **A tunnel** (Cloudflare / Tailscale) — real certificate, works remotely,
   but adds an account signup.

**Chosen for v1: option 1.** A native iOS client pins the self-signed
certificate and removes the warning entirely, which makes options 2 and 3
disposable work. See `ROADMAP.md`.

> Untested: whether the certificate exception survives Add-to-Home-Screen. A
> standalone web app may not inherit Safari's trust decision. If it doesn't, the
> warning returns — or the connection fails silently — on every launch.

## Connection methods

Working today, in the browser:

| Method | Range | Notes |
| --- | --- | --- |
| Same Wi-Fi (IP or `.local`) | LAN | Fails on networks with AP client isolation — most café and corporate Wi-Fi |
| Phone hotspot, Mac joins | Anywhere | Reliable fallback |
| Mac Internet Sharing, phone joins | Anywhere | Mac needs another uplink |
| USB cable | Physical | Lowest latency, no radio. Underrated |
| Tailscale / WireGuard | Global | Stable address over cellular, no port forwarding. Best remote option |
| Cloudflare Tunnel / ngrok | Global | Also yields a real certificate |
| Port forwarding + DDNS | Global | Exposes an input-injection server to the internet — avoid |

Native client only:

| Method | Why native |
| --- | --- |
| Multipeer / AWDL | Direct Wi-Fi+Bluetooth, no network at all |
| USB via usbmuxd | Sub-millisecond, works with Wi-Fi off |
| Bonjour discovery | Removes the QR step on a LAN |

**Not available:** BLE HID — the phone impersonating a Bluetooth mouse, working
on any computer with no server software. iOS gives apps no public API to act as
a HID peripheral.

## Failure states to design for

Each of these is currently invisible or cryptic, and each is a support ticket:

- Mac asleep, or the app not running
- Phone on a different network from the Mac
- **Accessibility revoked after an OS update** — the worst one: everything
  connects, the UI looks healthy, and nothing moves
- Port 8443 already in use
- Paired token rejected after `paired_devices.json` is cleared
