# Roadmap to v1

Ordered by dependency, not by appeal. Steps 1–3 are what stand between the
current proof of concept and something a stranger can install.

---

## 1. Swift port of the server — **done** (2026-09-01)

See [ADR-0002](adr/0002-port-input-injection-from-python-to-swift.md), which
records where its own recommendations turned out to be wrong.

- [x] Injection layer, verified message type by message type against the real
      cursor before anything else existed (`AirMouseInjector` still exists as a
      stdin-driven dev tool).
- [x] Accessibility layer (`focus_state`, `context`, `focus_keyboard`).
- [x] TLS + WebSocket + HTTP listener. **Not** Network framework — its TLS wants
      a Keychain-backed `SecIdentity`, which forces a "wants to sign using key"
      prompt on every start. swift-nio (`NIOSSL` + `NIOHTTP1` + `NIOWebSocket`)
      loads the PEM directly, like Python did.
- [x] Runs in-process inside `AirMouseBar`, not as a spawned child binary, so
      Accessibility is one grant on the app itself.
- [x] The web client runs against the Swift server.

Two rules from this phase were kept, and one was dropped:

- `docs/PROTOCOL.md` is the spec, not the Python source. **Kept.**
- Keep `mouse_controller.py` runnable as the reference. **Kept** — it is still
  there and still runnable.
- ~~Do not edit `web/index.html`.~~ **Dropped, deliberately.** Treating it as a
  frozen integration test was right while proving the port, and it did its job:
  the client working unmodified is what confirmed the wire protocol was correct.
  But two bugs turned out to *live in the client* — a missing `touchcancel`
  handler leaving the mouse button held (ADR-0006), and the keyboard-arming race
  (ADR-0008) — and holding the file immovable meant hunting for server-side
  workarounds to problems that had no server-side fix. A conformance test that
  cannot be corrected stops being a test and becomes a constraint.

Difficulty was uneven, roughly as predicted: the injection layer was mechanical
and genuinely shorter in Swift, and the server layer was the design work. The
unpredicted time went almost entirely into macOS platform behaviour — Keychain,
TCC grants keyed to a signature that changes on every build, and which thread an
Accessibility call is allowed to run on.

## 2. Self-contained, signed, notarized bundle

- [ ] Remove the `#filePath` repo-root assumption from `ServerManager`.
- [ ] Developer ID signing, notarization, and **stapling** (un-stapled apps fail
      to launch offline on first run).
- [ ] `.dmg` with an Applications symlink.
- [ ] Launch-at-login.
- [ ] Decide the update channel — Sparkle, or accept manual re-download.

## 3. First-run experience

- [ ] A real window on first launch, not a menu bar popover.
- [ ] Accessibility request via `AXIsProcessTrusted(prompt:)`, opening System
      Settings at the right pane.
- [ ] **Poll for the grant and advance automatically.** Never make the user come
      back and click "I did it".
- [ ] Automation permission for `switch_desktop`, requested only when first used.
- [ ] Large QR + PIN once permissions are granted.

## 4. Web client polish / PWA

- [x] **A certificate that actually matches the URL.** The cert was
      `CN=localhost` with no subjectAltName, served at `https://<host>.local`.
      Safari has ignored CN for hostname matching since iOS 13, so this was not
      a cosmetic warning — the cert could not be matched at all, and the "visit
      this website anyway" escape hatch is not reliably offered for it. Now
      carries SANs for the `.local` name, `localhost`, and every non-loopback
      IPv4 address, and regenerates when the machine's name or addresses change.
- [x] PWA manifest + icons (`web/make_icons.swift` regenerates them from the
      same SF Symbol as the menu bar item).
- [x] Add-to-Home-Screen coaching, with the Share glyph. Shown once after
      pairing succeeds, and only where it is possible and not already installed.
- [x] **Accessibility revoked** — was silent, which is the worst failure the app
      has: everything connects, every message is accepted, and nothing moves.
      The server now reports the grant on the `permission` message and the
      client shows a banner naming the pane to re-enable it in.
- [ ] Guided certificate-warning step with screenshots.
- [ ] Remaining states: Mac asleep / not running, phone on another network,
      port already in use.
- [ ] Offer the certificate for download so it can be trusted outright. This is
      what would remove the warning entirely on the PWA path — see the open
      question below.

## 5. Native iOS client

Only after the feature set stops moving.

- [ ] Shared Swift protocol package with `Codable` types, consumed by both ends.
- [ ] Certificate pinning — removes the browser warning entirely.
- [ ] Bonjour discovery — removes the QR step on a LAN.
- [ ] Core Haptics — replaces the hidden-checkbox haptic hack, and gives
      *different* feels for tap / drag-lock / scroll detents.
- [ ] CoreMotion — 100 Hz quaternions instead of the throttled browser API.

---

## Deliberately deferred

- **A real certificate for the web client** (public DNS to a private IP, or a
  tunnel). The native client pins the self-signed cert instead, which makes this
  work disposable. Guide the warning for v1.
- **Elaborate QR tooling.** Bonjour obsoletes it.
- **Porting the client's gesture logic to Swift.** The web client stays
  permanently: it is the zero-install path and the only Android story.

## Open questions

- Does the certificate exception survive Add-to-Home-Screen? A home-screen web
  app does not share Safari's per-site exception store, so the expectation is
  **no** — and a standalone web app has no interstitial to tap through, so it
  fails with nothing useful on screen. Now testable: the cert is finally valid
  for the hostname, so the remaining question is purely about trust, not
  matching. If it does fail, the fix is a one-time trusted-certificate install
  on the phone (Settings › General › About › Certificate Trust Settings), which
  is more setup steps but removes the warning permanently — a self-signed leaf
  trusted this way can only vouch for itself, unlike installing a CA.
- Is `switch_desktop` reproducible natively in Swift, or does the AppleScript
  path have to stay? Still open — the port kept the AppleScript path rather than
  gambling on it, and it works. See the port note in `PROTOCOL.md`.
- Update channel for a non–App Store Mac app.

## Known rough edges

- Gesture-feedback toasts (`Drag active`, `Right Click`, `Double Click`,
  `Previous/Next Desktop`) still fire during normal use. The dot grid could
  carry these instead, as the green success pulse already does.
- ~~The `[AX] role=… selection=…` server log fires on every tap.~~ Removed in
  the Swift port.
- The full-width input bar overlaps the bottom-edge horizontal-scroll strip
  (bottom 10 % of the touch surface).
