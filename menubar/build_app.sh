#!/bin/bash
# Builds AirMouseBar and packages it into a double-clickable .app bundle.
#
# The bundle must be self-contained: the app serves the web client from
# Contents/Resources/web, never from the checkout it was built in (see ADR-0002).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-debug}"

# Release builds should be universal: an arm64-only binary will not launch at all
# on an Intel Mac, with no useful error for the user. Multi-arch builds need full
# Xcode (xcbuild); with only Command Line Tools installed we fall back to a native
# build and say so, rather than failing. CI has Xcode, so released artifacts are
# universal even when local ones aren't.
# Detected with `xcodebuild -version`, which succeeds only under a full Xcode.
# The previous probe tested for a SharedFrameworks path that does not exist on
# the GitHub runner, so CI silently shipped an arm64-only build while the site
# advertised Intel support.
#
# REQUIRE_UNIVERSAL=1 turns that silent fallback into a hard failure. CI sets it:
# a release that quietly drops half the supported machines is worse than a
# release that does not build.
ARCH_FLAGS=()
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"
if [ "$CONFIG" = "release" ]; then
    if xcodebuild -version >/dev/null 2>&1; then
        ARCH_FLAGS=(--arch arm64 --arch x86_64)
    elif [ "$REQUIRE_UNIVERSAL" = "1" ]; then
        echo "error: REQUIRE_UNIVERSAL=1 but no full Xcode is available." >&2
        echo "       xcode-select -p => $(xcode-select -p 2>/dev/null || echo none)" >&2
        exit 1
    else
        echo "warning: full Xcode not found — building for $(uname -m) only."
        echo "         This build will NOT run on Intel Macs."
    fi
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/AirMouseBar"
APP_DIR="$SCRIPT_DIR/AirMouseBar.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_PATH" "$CONTENTS_DIR/MacOS/AirMouseBar"

# The web client, served over HTTPS to the phone. Build tooling that happens to
# live in web/ is excluded — everything copied here is reachable over HTTP, and
# the icon generator is not part of the client.
cp -R "$REPO_ROOT/web" "$CONTENTS_DIR/Resources/web"
rm -f "$CONTENTS_DIR/Resources/web/"*.swift

# The uninstaller, so the app's "Uninstall…" button and the terminal path run
# exactly the same script rather than two drifting definitions of "installed".
cp "$SCRIPT_DIR/reset_install.sh" "$CONTENTS_DIR/Resources/reset_install.sh"

# Sparkle, for in-place updates.
#
# SwiftPM links it but does not embed it — that is normally Xcode's job, and this
# bundle is assembled by hand. Without the copy plus the added rpath the app dies
# at launch with "Library not loaded: @rpath/Sparkle.framework".
SPARKLE_FRAMEWORK="$(find "$SCRIPT_DIR/.build/artifacts" -type d -name "Sparkle.framework" -path "*macos*" -print -quit)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "error: Sparkle.framework not found — run 'swift package resolve' first" >&2
    exit 1
fi
mkdir -p "$CONTENTS_DIR/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS_DIR/MacOS/AirMouseBar" 2>/dev/null || true

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Air Mouse</string>
    <key>CFBundleIdentifier</key>
    <string>com.airmouse.menubar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>AirMouseBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Air Mouse uses System Events to switch desktops when you swipe on your phone.</string>

    <!-- Sparkle. SUPublicEDKey must be the public half of the EdDSA key used to
         sign releases; without it Sparkle refuses every update, which is the
         point — it is what stops a hostile feed from shipping you a binary. -->
    <key>SUFeedURL</key>
    <string>__SU_FEED_URL__</string>
    <key>SUPublicEDKey</key>
    <string>__SU_PUBLIC_ED_KEY__</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

# Sparkle configuration, injected so the key never has to live in this script.
#   SU_FEED_URL       — appcast.xml URL (GitHub Releases or raw.githubusercontent)
#   SU_PUBLIC_ED_KEY  — output of Sparkle's generate_keys
# Version. Sparkle decides whether an update exists by comparing CFBundleVersion,
# so a hardcoded one means no build is ever newer than the one already installed
# and the updater silently never fires — which would quietly defeat the whole
# point of ADR-0009. CI passes the git tag; local builds get an obvious 0.0.0.
APP_VERSION="${APP_VERSION:-0.0.0}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_DIR/Info.plist"

FEED_URL="${SU_FEED_URL:-https://github.com/taycay47/air-mouse/releases/latest/download/appcast.xml}"
# Not a secret: it ships in every copy of the app. Its whole job is to let the app
# reject an update that wasn't signed with the matching private key. Hardcoded so
# it cannot drift out of sync with the key CI signs with.
PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-3FAQkXNQXLXP7472SujcE5AeJKxIKgSGw71i6UcIbBE=}"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$CONTENTS_DIR/Info.plist"
if [ -n "$PUBLIC_ED_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_ED_KEY" "$CONTENTS_DIR/Info.plist"
else
    # No key yet: strip the placeholder rather than ship a bogus one.
    /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$CONTENTS_DIR/Info.plist"
    echo "note: SU_PUBLIC_ED_KEY unset — updates will not be verifiable until it is."
fi

# Signing.
#
# Accessibility permission is remembered against the app's code signature, so an
# unsigned/ad-hoc build loses the grant whenever the signature changes — i.e. on
# every update. A Developer ID also avoids Gatekeeper blocking the download.
# Set CODESIGN_IDENTITY to a "Developer ID Application: ..." identity to get both;
# otherwise this falls back to ad-hoc so the app at least runs locally.
IDENTITY="${CODESIGN_IDENTITY:--}"

# Sign inside-out. Sparkle ships its own nested executables (XPC services,
# Updater.app, Autoupdate) which must each be signed before the framework, and the
# framework before the app — --deep is unreliable for this and deprecated for
# Developer ID.
sign() {
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --sign - "$1"
    else
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
    fi
}

SPARKLE_IN_APP="$CONTENTS_DIR/Frameworks/Sparkle.framework"
for nested in \
    "$SPARKLE_IN_APP/Versions/B/XPCServices/"*.xpc \
    "$SPARKLE_IN_APP/Versions/B/Updater.app" \
    "$SPARKLE_IN_APP/Versions/B/Autoupdate"
do
    [ -e "$nested" ] && sign "$nested"
done
sign "$SPARKLE_IN_APP"
sign "$APP_DIR"

if [ "$IDENTITY" = "-" ]; then
    echo "note: ad-hoc signed. Gatekeeper will warn on other Macs, and the"
    echo "      Accessibility grant will not survive an update."
fi

# Assert the result rather than trusting the flags: this is the check that would
# have caught the arm64-only release before it was published.
if [ "$REQUIRE_UNIVERSAL" = "1" ]; then
    PRODUCED_ARCHS="$(lipo -archs "$CONTENTS_DIR/MacOS/AirMouseBar" 2>/dev/null || echo unknown)"
    case "$PRODUCED_ARCHS" in
        *arm64*x86_64*|*x86_64*arm64*) echo "universal: $PRODUCED_ARCHS" ;;
        *) echo "error: expected a universal binary, got: $PRODUCED_ARCHS" >&2; exit 1 ;;
    esac
fi

echo "Built $APP_DIR"
