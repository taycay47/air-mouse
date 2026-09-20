#!/bin/bash
# Removes every trace of Air Mouse from this Mac, so the next install from the
# .dmg is genuinely a cold one.
#
#   ./reset_install.sh --dry-run    # show what would be removed, change nothing
#   ./reset_install.sh              # show, then ask before removing
#   ./reset_install.sh --yes        # no prompt (for scripted test loops)
#
# Why this needs to be a script rather than dragging the app to the Trash:
# three of the five things Air Mouse leaves behind are invisible in Finder, and
# any one of them makes a "cold" install warm.
#
#   - The Accessibility grant lives in TCC, not in the bundle. Reinstalling over
#     a grant that is still present skips the single step most likely to be
#     broken, which is the step worth testing.
#   - Preferences are cached by cfprefsd. Deleting the plist alone can be
#     silently undone when the daemon next flushes, so the domain has to be
#     deleted through `defaults` first.
#   - paired_devices.json means the phone skips PIN entry, so pairing looks like
#     it works when it has not actually been exercised.
set -euo pipefail

BUNDLE_ID="com.airmouse.menubar"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --yes|-y)  ASSUME_YES=true ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Everything that could exist. Absent entries are reported and skipped, so this
# stays readable when run twice.
PATHS=(
    "/Applications/Air Mouse.app"
    "$SCRIPT_DIR/AirMouseBar.app"
    "$HOME/Library/Application Support/AirMouse"
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    "$HOME/Library/Caches/$BUNDLE_ID"
    "$HOME/Library/Application Support/Caches/$BUNDLE_ID"
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/WebKit/$BUNDLE_ID"
)

echo "Air Mouse — full reset"
echo

echo "Running processes:"
if pgrep -x AirMouseBar >/dev/null 2>&1 || pgrep -x AirMouseServer >/dev/null 2>&1; then
    pgrep -xl "AirMouseBar|AirMouseServer" 2>/dev/null || pgrep -fl "AirMouse" 2>/dev/null || true
else
    echo "  (none)"
fi
echo

echo "Files and bundles:"
FOUND_ANY=false
for path in "${PATHS[@]}"; do
    if [ -e "$path" ]; then
        SIZE="$(du -sh "$path" 2>/dev/null | cut -f1 || echo '?')"
        echo "  remove   $path  ($SIZE)"
        FOUND_ANY=true
    else
        echo "  absent   $path"
    fi
done
echo

echo "Permissions and preferences:"
echo "  reset    TCC Accessibility  ($BUNDLE_ID)"
echo "  reset    TCC Automation / AppleEvents  ($BUNDLE_ID)"
echo "  delete   defaults domain  $BUNDLE_ID"
echo

cat <<'NOTE'
Not touched (belongs to the Python reference server, not the app):
  ./cert.pem  ./key.pem  ./paired_devices.json  in the repo root

Cannot be reset from the Mac — do these on the phone for a true cold run:
  1. Delete the Air Mouse icon from the Home Screen, if you added it.
  2. Safari > Clear History, or at minimum clear website data for the Mac's
     hostname. This drops the saved pairing token and the accepted certificate
     exception; without it the phone reconnects without ever showing the PIN.
NOTE
echo

if [ "$DRY_RUN" = true ]; then
    echo "Dry run — nothing was changed."
    exit 0
fi

if [ "$ASSUME_YES" != true ]; then
    printf 'Proceed? [y/N] '
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
    echo
fi

# 1. Stop the app first. Removing a running bundle leaves the process alive,
#    still holding its port and still able to rewrite its preferences.
for proc in AirMouseBar AirMouseServer; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        echo "quitting $proc"
        pkill -x "$proc" 2>/dev/null || true
    fi
done
# Give them a moment to exit cleanly (held mouse buttons are released on SIGTERM
# — see ADR-0006), then insist.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x AirMouseBar >/dev/null 2>&1 || pgrep -x AirMouseServer >/dev/null 2>&1 || break
    sleep 0.3
done
pkill -9 -x AirMouseBar 2>/dev/null || true
pkill -9 -x AirMouseServer 2>/dev/null || true

# 2. Preferences through `defaults` before the file, so cfprefsd does not write
#    its cached copy back out after the plist is gone.
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "deleting defaults domain $BUNDLE_ID"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
fi

# 3. Files.
for path in "${PATHS[@]}"; do
    if [ -e "$path" ]; then
        echo "removing $path"
        rm -rf "$path"
    fi
done

# 4. TCC. Non-fatal: tccutil exits non-zero when there is no entry to reset,
#    which is the normal case on a machine that was already clean.
echo "resetting Accessibility permission"
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 \
    && echo "  ok" || echo "  no existing grant (fine)"
echo "resetting Automation permission"
tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 \
    && echo "  ok" || echo "  no existing grant (fine)"

echo
echo "Done. Air Mouse is gone from this Mac."
echo "Mount AirMouse.dmg and drag it to Applications to test the cold path."
