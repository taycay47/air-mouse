# ADR-0009 — Updates ship via Sparkle, under a stable Developer ID

**Status:** Accepted · 2026-09-01

## Context

Distribution is direct download, not the Mac App Store (ADR-0001), so nothing
updates the app on its own. Without an updater the only route is "notice a new
version exists, download it, drag it over the old one" — which in practice means
users stay on whatever version they first installed.

## The part that is specific to this app

macOS remembers the Accessibility grant against the app's **code signature**.

Air Mouse cannot do anything at all without that grant, so an update that changes
the signature does not merely annoy the user — it silently breaks the app. It
launches, the menu bar looks healthy, the phone pairs, and nothing moves. This
exact failure showed up repeatedly during the Swift port, where every `swift
build` re-signed the binary ad-hoc and quietly invalidated the grant.

Two consequences follow:

1. **A Developer ID is not optional.** Ad-hoc signatures change per build, so
   every update would revoke permission. A stable Developer ID keeps it.
2. **Updates should replace the app in place** rather than have the user drag a
   new copy over the old one, so the bundle identity the system recognises stays
   continuous.

## Decision

Sparkle, fed by an appcast published to GitHub Releases, with the app signed by a
Developer ID Application certificate and notarized.

Releases are cut by pushing a tag; CI builds, signs, notarizes, staples,
generates the appcast and publishes. No manual release steps.

## Why Sparkle

It is the de facto standard for non-App-Store Mac apps, it handles the parts that
are easy to get subtly wrong (atomic replacement, privileged install, relaunch),
and it verifies every update against an EdDSA public key compiled into the app.
That last point matters: the feed lives on GitHub, so signature verification is
what stops a compromised release or a hijacked URL from delivering a binary that
inherits the user's Accessibility permission.

## Consequences

- Two separate signing systems, easily confused. **Developer ID** signs the app
  for Gatekeeper and preserves the Accessibility grant; **Sparkle's EdDSA key**
  signs the update payload. Both are required, neither substitutes for the other.
- The EdDSA private key is a release secret. Losing it means shipping an update
  is impossible without users manually reinstalling; leaking it means someone
  else can. It lives in CI secrets only.
- `build_app.sh` has to embed and sign `Sparkle.framework` by hand — SwiftPM links
  it but does not embed it, that being Xcode's job, and this bundle is assembled
  by a script. The framework carries its own nested executables (XPC services,
  `Updater.app`, `Autoupdate`) which must be signed inside-out.
- CI degrades rather than fails when the secrets are absent: it still produces a
  `.dmg`, just an unsigned one with no appcast. Useful for testing the pipeline,
  never for an actual release.
