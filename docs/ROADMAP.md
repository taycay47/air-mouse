# Roadmap to v1

Ordered by dependency, not by appeal. Steps 1–3 are what stand between the
current proof of concept and something a stranger can install.

---

## 1. Swift port of the server — **critical path**

See [ADR-0002](adr/0002-port-input-injection-from-python-to-swift.md).

- [ ] Injection layer as a standalone Swift CLI driven from stdin. Verify each
      message type physically moves the cursor / types / scrolls **before**
      anything else exists.
- [ ] Accessibility layer (`focus_state`, `context`).
- [ ] TLS + WebSocket + HTTP listener. Prefer Network framework
      (`NWListener` / `NWProtocolTLS` / `NWProtocolWebSocket`) — Apple-native,
      no SPM dependencies to vendor and notarize.
- [ ] Conformance: **`web/index.html` runs unmodified against the Swift server.**

Rules for this phase:

- `docs/PROTOCOL.md` is the spec, not the Python source.
- Do **not** edit `web/index.html`. It is the integration test.
- Keep `mouse_controller.py` runnable as the reference until conformance passes.

Difficulty is uneven — roughly 60 % mechanical, 15 % needing real Swift C-interop
knowledge, 25 % genuine design work in the server layer. Delegate accordingly;
the server layer is not a translation task.

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

## 4. Web client polish

- [ ] Add-to-Home-Screen coaching, with a picture of the Share icon. Without
      this, users re-scan a QR code forever.
- [ ] Guided certificate-warning step with screenshots.
- [ ] Real states for: Mac asleep / not running, phone on another network,
      **Accessibility revoked** (currently silent — everything connects and
      nothing moves), port already in use.
- [ ] PWA manifest + icons.

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

- Does the certificate exception survive Add-to-Home-Screen? If not, the PWA
  shows the warning (or fails silently) on every launch, which would move the
  native client up the list.
- Is `switch_desktop` reproducible natively in Swift, or does the AppleScript
  path have to stay? See the port note in `PROTOCOL.md`.
- Update channel for a non–App Store Mac app.

## Known rough edges

- Gesture-feedback toasts (`Drag active`, `Right Click`, `Double Click`,
  `Previous/Next Desktop`) still fire during normal use. The dot grid could
  carry these instead, as the green success pulse already does.
- The `[AX] role=… selection=…` server log fires on every tap. Useful now,
  log spam for production.
- The full-width input bar overlaps the bottom-edge horizontal-scroll strip
  (bottom 10 % of the touch surface).
