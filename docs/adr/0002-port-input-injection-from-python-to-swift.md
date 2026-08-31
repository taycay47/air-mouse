# ADR-0002 — Port input injection from Python to Swift

**Status:** Accepted · 2026-08-31 · **Not yet implemented**

## Context

`mouse_controller.py` performs all input injection through `ctypes` bindings to
CoreGraphics. `menubar/` is a Swift menu bar app that spawns it as a child
process.

Three problems block distribution:

1. **The bundle is not portable.** `ServerManager` derives the repo root from
   `#filePath` — the *compile-time* source path — then launches
   `.venv/bin/python3` and `mouse_controller.py` from that checkout. On any
   other machine it fails immediately.
2. **No Python runtime ships.** Bundling one costs ~40 MB and complicates
   notarization.
3. **Accessibility is granted to the wrong binary.** Because Python posts the
   events, the user must grant Accessibility to `.venv/bin/python3` — a hidden
   file inside a bundle, located through a file picker. This is not something a
   real user will do.

## Decision

Port the input-injection and Accessibility layers to Swift and drop the Python
dependency. The `.app` becomes self-contained and requests Accessibility for
itself.

## Why now

Any one of the three problems could be worked around. Together they make the app
undistributable, so this moves from "natural next step" (as `menubar/README.md`
already called it) onto the critical path for v1.

The planned native iOS client raises the value further: a Swift server and a
Swift client can share one protocol package with `Codable` types, instead of
maintaining a third independent implementation of the wire format.

## Effort, honestly

Measured against the current 890-line server:

| Area | Lines | Difficulty |
| --- | --- | --- |
| CGEvent injection, key tables, desktop bounds | ~250 | Near 1:1, and *shorter* in Swift — 44 lines of `ctypes` signature plumbing simply delete |
| Accessibility (`_copy_ax_string`, `_check_text_focus`) | ~75 | Collapses in Swift, but needs real `Unmanaged`/`CFTypeRef` knowledge |
| `handle_ws_client` protocol dispatch + session state | ~240 | Translatable but highest-risk: mutable state across packets is where subtle drift hides |
| TLS + WebSocket + HTTP on one port | ~90 | **Not a translation.** No Swift equivalent to `websockets.serve(process_request=…)` |

The server layer is a design task, not a port. Preferred approach: Network
framework (`NWListener` + `NWProtocolTLS` + `NWProtocolWebSocket`) — Apple-native
and dependency-free, which keeps notarization simple. The HTTP static-file side
is small enough to hand-roll, and shrinks further once the iOS client bundles
its own assets.

## Consequences

- `mouse_controller.py` stays as the reference implementation until the port
  passes conformance.
- **`web/index.html` must not change during the port.** It is a free, thorough
  integration test — every gesture, edge-scroll, drag-lock, pairing flow, and
  context pill. If the existing client works unmodified against the Swift
  server, the port is correct.
- `docs/PROTOCOL.md` is the specification, written before the second
  implementation exists rather than reverse-engineered afterwards.
