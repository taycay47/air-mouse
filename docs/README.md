# Documentation

- **[PROTOCOL.md](PROTOCOL.md)** — the wire protocol between phone and Mac.
  The specification for the Swift port; read this before touching either end.
- **[ROADMAP.md](ROADMAP.md)** — ordered, actionable steps to v1.
- **[ONBOARDING.md](ONBOARDING.md)** — the intended user journey, connection
  methods, and failure states.
- **[adr/](adr/)** — architecture decision records.

## Decisions

| # | Decision |
| --- | --- |
| [0001](adr/0001-distribution-developer-id-not-mac-app-store.md) | Notarized `.dmg`, not the Mac App Store |
| [0002](adr/0002-port-input-injection-from-python-to-swift.md) | Port input injection from Python to Swift |
| [0003](adr/0003-ios-keyboard-viewport-strategy.md) | Pin the scene to the visual viewport |
| [0004](adr/0004-focus-state-is-advisory-never-gating.md) | Accessibility state is advisory, never gating |
| [0005](adr/0005-context-detection-is-event-driven-and-fail-closed.md) | Context detection: event-driven, fail-closed |
| [0006](adr/0006-held-buttons-must-always-be-released.md) | Held mouse buttons must always be released |
| [0007](adr/0007-vendor-motion-drop-gsap.md) | Vendor Motion locally; drop GSAP |
