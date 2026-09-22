#!/bin/bash
# Builds AirMouseBar.app and packages it as a distributable .dmg with the
# conventional drag-to-Applications layout.
#
#   ./make_dmg.sh            # release build
#   ./make_dmg.sh debug      # debug build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-release}"
APP_DIR="$SCRIPT_DIR/AirMouseBar.app"
DMG_PATH="$SCRIPT_DIR/AirMouse.dmg"
VOLUME_NAME="Air Mouse"
STAGING="$(mktemp -d)"
WRITABLE="$(mktemp -d)/rw.dmg"
MOUNTPOINT=""
# Every step guarded, because this runs under `set -e` on the way out of a
# *successful* build too. An unguarded "a && b" whose b fails — detaching a
# volume that is already gone, which is the normal path — makes the list fail,
# which aborts the trap, which becomes the script's exit status. The disk image
# is built and correct and the build reports failure.
cleanup() {
    if [ -n "$MOUNTPOINT" ]; then
        hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null || true
    fi
    rm -rf "$STAGING" "$(dirname "$WRITABLE")" 2>/dev/null || true
    return 0
}
trap cleanup EXIT

./build_app.sh "$CONFIG"

# Drag-to-install layout: the app beside a symlink to /Applications.
cp -R "$APP_DIR" "$STAGING/Air Mouse.app"
ln -s /Applications "$STAGING/Applications"

# The window's backdrop, generated from the same logo path as the app icon by
# design/make_app_icon.swift. Combined into one file carrying both resolutions:
# Finder picks the 2x representation on a Retina display, and given only a 1x
# PNG it upscales it, which is exactly where a backdrop looks cheap.
BACKGROUND_SRC="$SCRIPT_DIR/dmg"
if [ -f "$BACKGROUND_SRC/background.png" ]; then
    mkdir -p "$STAGING/.background"
    if [ -f "$BACKGROUND_SRC/background@2x.png" ] && command -v tiffutil >/dev/null 2>&1; then
        tiffutil -cathidpicheck \
            "$BACKGROUND_SRC/background.png" \
            "$BACKGROUND_SRC/background@2x.png" \
            -out "$STAGING/.background/background.tiff" >/dev/null 2>&1 \
            || cp "$BACKGROUND_SRC/background.png" "$STAGING/.background/background.tiff"
    else
        cp "$BACKGROUND_SRC/background.png" "$STAGING/.background/background.tiff"
    fi
fi

# The recorded window layout.
#
# Finder stores a folder's appearance in .DS_Store, and the only way to write
# one is to have Finder do it — which needs a window server and the Automation
# permission. CI has neither, so without this the disk image people actually
# download would be the one plain, unstyled build while local ones looked right.
#
# So a known-good .DS_Store is checked in and seeded here. Refresh it with
# EXPORT_DMG_LAYOUT=1 ./make_dmg.sh after changing the window or the backdrop.
if [ -f "$SCRIPT_DIR/dmg/DS_Store" ]; then
    cp "$SCRIPT_DIR/dmg/DS_Store" "$STAGING/.DS_Store"
fi

# A read-write image first, because the window's appearance is stored *in* the
# volume: Finder writes it to .DS_Store, which cannot be done to a compressed,
# read-only image. So: build it writable, arrange it, then convert.
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDRW \
    "$WRITABLE" >/dev/null

# Mounted under /Volumes, deliberately, rather than at a temp mountpoint.
# Finder addresses volumes by name and only knows about the ones mounted where
# it expects them — pointed at a private mountpoint, `tell disk "Air Mouse"`
# raises "can't get disk" and every bit of styling below silently does nothing.
#
# The real path is read back rather than assumed: if a volume of this name is
# already mounted, macOS quietly appends a number, and styling the wrong disk
# would be worse than styling none.
ATTACH_OUTPUT="$(hdiutil attach "$WRITABLE" -readwrite -noverify -noautoopen)"
MOUNTPOINT="$(printf '%s\n' "$ATTACH_OUTPUT" | grep -o '/Volumes/.*$' | tail -1)"
if [ -z "$MOUNTPOINT" ]; then
    echo "error: could not determine where the image mounted" >&2
    exit 1
fi
MOUNTED_NAME="$(basename "$MOUNTPOINT")"

# Everything from here to the detach is best-effort. It drives Finder through
# AppleScript, which needs a logged-in window server and the Automation
# permission — neither of which exists on a CI runner. A plain, unstyled disk
# image is a perfectly good disk image, so a failure here is a note, not an
# error.
style_window() {
    osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    tell disk "$MOUNTED_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 660x420 of content, matching the backdrop's dimensions exactly. Any
        -- other size and the image is anchored to a corner and the arrow no
        -- longer points between the icons.
        set the bounds of container window to {200, 140, 860, 560}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 96
        -- A POSIX path, not Finder's colon notation. Inside a "tell disk"
        -- block, file ".background:background.tiff" resolves against something
        -- other than the disk, and Finder accepts it without complaint —
        -- leaving the window with no backdrop and no error to notice.
        --
        -- No backticks anywhere in this script: the heredoc below is unquoted
        -- so that $MOUNTPOINT expands, which means backticks are command
        -- substitution and a comment containing one silently mangles the
        -- AppleScript around it.
        set background picture of options to POSIX file "$MOUNTPOINT/.background/background.tiff"
        set position of item "Air Mouse.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
}

# DMG_SKIP_FINDER=1 skips the attempt entirely and relies on the checked-in
# layout. CI sets it: there is no Finder there, so the attempt can only fail
# slowly and print a note that reads like a problem.
if [ "${DMG_SKIP_FINDER:-0}" = "1" ]; then
    echo "using the recorded window layout (Finder not consulted)"
elif style_window; then
    echo "styled the disk image window"
else
    echo "note: could not arrange the window (no Finder session?) —"
    echo "      falling back to the recorded layout in dmg/DS_Store."
fi

# The volume's own icon, so the mounted disk on the desktop and in the sidebar
# is the app rather than a blank drive. It reuses the .icns actool compiled into
# the bundle, taken from the copy already on the volume.
#
# Written here, after Finder has finished with the window, rather than into the
# staging folder before the image is built: staged, the file is present when the
# image is created and gone by the time it ships. Finder appears to absorb it
# into the volume's own icon record while it has the disk open, which leaves the
# attribute set on a volume with nothing to draw.
VOLUME_ICNS="$MOUNTPOINT/Air Mouse.app/Contents/Resources/AirMouse.icns"
if [ -f "$VOLUME_ICNS" ] && command -v SetFile >/dev/null 2>&1; then
    cp "$VOLUME_ICNS" "$MOUNTPOINT/.VolumeIcon.icns"
    # Without the attribute the .icns sits there being ignored.
    SetFile -a C "$MOUNTPOINT" 2>/dev/null || true
    SetFile -a V "$MOUNTPOINT/.VolumeIcon.icns" 2>/dev/null || true
    echo "set the volume icon"
fi

sync
# Detaching straight after Finder has been writing to the volume frequently
# fails with "resource busy", and the first failure is not a real one.
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null; then break; fi
    sleep 1
    [ "$attempt" = "5" ] && hdiutil detach "$MOUNTPOINT" -force -quiet 2>/dev/null || true
done

# ULFO (LZFSE) rather than UDZO (zlib): smaller, and decompressed by the same
# hardware-friendly codec the rest of the system uses. Supported since 10.15,
# which is well below this app's floor of 13.
hdiutil convert "$WRITABLE" -format ULFO -o "$DMG_PATH" -ov >/dev/null

# Recording the layout, from the finished image rather than from the writable
# one. Finder settles a folder's .DS_Store as it closes and unmounts, so a copy
# taken mid-flight catches a half-written one — which is how the first attempt
# came away with icon positions but no view options at all.
if [ "${EXPORT_DMG_LAYOUT:-0}" = "1" ]; then
    EXPORT_MOUNT="$(hdiutil attach "$DMG_PATH" -noautoopen -nobrowse -quiet 2>/dev/null \
        && mount | grep -o '/Volumes/[^(]*' | tail -1 | sed 's/ *$//')"
    if [ -n "$EXPORT_MOUNT" ] && [ -f "$EXPORT_MOUNT/.DS_Store" ]; then
        cp "$EXPORT_MOUNT/.DS_Store" "$SCRIPT_DIR/dmg/DS_Store"
        echo "recorded the window layout to dmg/DS_Store"
    fi
    [ -n "$EXPORT_MOUNT" ] && hdiutil detach "$EXPORT_MOUNT" -quiet 2>/dev/null || true
fi

echo "Built $DMG_PATH"
du -h "$DMG_PATH" | cut -f1
shasum -a 256 "$DMG_PATH"

if [ "${CODESIGN_IDENTITY:--}" = "-" ]; then
    cat <<'NOTE'

note: this .dmg is not signed or notarized, so macOS will refuse to open it on
      first launch with "Air Mouse cannot be opened because the developer cannot
      be verified". Recipients have to allow it under System Settings → Privacy
      & Security → Open Anyway.

      This is the one thing no amount of tooling fixes — it needs a paid
      Developer ID, not a better script:

        CODESIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./make_dmg.sh release
        xcrun notarytool submit AirMouse.dmg --keychain-profile AC_PASSWORD --wait
        xcrun stapler staple AirMouse.dmg
NOTE
fi
