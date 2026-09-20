#!/bin/bash
# Builds AirMouseBar.app and packages it as a distributable .dmg with the
# conventional drag-to-Applications layout.
#
#   ./make_dmg.sh            # debug build
#   ./make_dmg.sh release    # release build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-release}"
APP_DIR="$SCRIPT_DIR/AirMouseBar.app"
DMG_PATH="$SCRIPT_DIR/AirMouse.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

./build_app.sh "$CONFIG"

# Drag-to-install layout: the app beside a symlink to /Applications.
cp -R "$APP_DIR" "$STAGING/Air Mouse.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "Air Mouse" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

echo "Built $DMG_PATH"
shasum -a 256 "$DMG_PATH"

if [ "${CODESIGN_IDENTITY:--}" = "-" ]; then
    cat <<'NOTE'

note: this .dmg is not signed or notarized, so macOS will refuse to open it on
      first launch with "Air Mouse cannot be opened because the developer cannot
      be verified". Recipients have to right-click the app and choose Open, or
      allow it under System Settings → Privacy & Security.

      To fix properly, set CODESIGN_IDENTITY to a Developer ID Application
      identity and notarize:

        CODESIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./make_dmg.sh release
        xcrun notarytool submit AirMouse.dmg --keychain-profile AC_PASSWORD --wait
        xcrun stapler staple AirMouse.dmg
NOTE
fi
