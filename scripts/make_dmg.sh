#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <app_path> <output_dmg> [sign_identity] [notary_profile]" >&2
    exit 1
fi

APP_PATH="$1"
OUT_DMG="$2"
SIGN_IDENTITY="${3:-}"
NOTARY_PROFILE="${4:-}"
VOL_NAME="PeanutButter"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at: $APP_PATH" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BG_IMAGE="$REPO_ROOT/assets/dmg-background.png"
VOL_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"

mkdir -p "$(dirname "$OUT_DMG")"

TMP_WORK=$(mktemp -d /tmp/pb_dmg.XXXXXX)
DEVICE=""
cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach -force "$DEVICE" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_WORK"
}
trap cleanup EXIT

DMG_STAGE="$TMP_WORK/stage"
RW_DMG="$TMP_WORK/PeanutButter-rw.dmg"
mkdir -p "$DMG_STAGE"

echo "Staging DMG contents for $VOL_NAME..."
ditto "$APP_PATH" "$DMG_STAGE/PeanutButter.app"
ln -s /Applications "$DMG_STAGE/Applications"

HAS_BG=0
if [ -f "$BG_IMAGE" ]; then
    mkdir -p "$DMG_STAGE/.background"
    cp "$BG_IMAGE" "$DMG_STAGE/.background/background.png"
    HAS_BG=1
fi

if [ -f "$VOL_ICON" ]; then
    cp "$VOL_ICON" "$DMG_STAGE/.VolumeIcon.icns"
fi

STAGE_MB=$(du -sm "$DMG_STAGE" | awk '{print $1}')
DMG_SIZE_MB=$((STAGE_MB + 64))
if [ "$DMG_SIZE_MB" -lt 128 ]; then
    DMG_SIZE_MB=128
fi

echo "Creating temporary read-write DMG (${DMG_SIZE_MB} MB)..."
hdiutil create \
    -srcfolder "$DMG_STAGE" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${DMG_SIZE_MB}m" \
    "$RW_DMG" >/dev/null

ATTACH_OUT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")
DEVICE=$(printf '%s\n' "$ATTACH_OUT" | awk '/\/Volumes\// {print $1; exit}')
MOUNT_DIR=$(printf '%s\n' "$ATTACH_OUT" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | head -n 1)

if [ -z "$DEVICE" ] || [ -z "$MOUNT_DIR" ]; then
    echo "ERROR: Failed to attach temporary DMG." >&2
    exit 1
fi
MOUNT_VOL_NAME="$(basename "$MOUNT_DIR")"

if command -v SetFile >/dev/null 2>&1; then
    if [ -f "$MOUNT_DIR/.VolumeIcon.icns" ]; then
        SetFile -a C "$MOUNT_DIR" || true
        SetFile -a V "$MOUNT_DIR/.VolumeIcon.icns" || true
    fi
    if [ -d "$MOUNT_DIR/.background" ]; then
        SetFile -a V "$MOUNT_DIR/.background" || true
    fi
fi

echo "Applying Finder icon layout and drag-and-drop background..."
if ! osascript - "$MOUNT_VOL_NAME" "$HAS_BG" <<'APPLESCRIPT'
on run argv
    set volName to item 1 of argv
    set hasBg to (item 2 of argv) as integer
    tell application "Finder"
        tell disk volName
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 800, 548}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 108
            if hasBg = 1 then
                set background picture of viewOptions to file ".background:background.png"
            end if
            set position of item "PeanutButter.app" of container window to {165, 205}
            set position of item "Applications" of container window to {435, 205}
            close
            open
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
APPLESCRIPT
then
    echo "  Note: Finder window layout skipped (non-interactive or headless session); DMG contents remain intact."
fi

chmod -Rf go-w "$MOUNT_DIR" >/dev/null 2>&1 || true
sync
sleep 1

DETACHED=0
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$DEVICE" >/dev/null 2>&1; then
        DETACHED=1
        DEVICE=""
        break
    fi
    sleep 2
done
if [ "$DETACHED" -ne 1 ]; then
    hdiutil detach -force "$DEVICE" >/dev/null 2>&1 || true
    DEVICE=""
fi

echo "Converting DMG to compressed read-only image ($OUT_DMG)..."
rm -f "$OUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing $OUT_DMG with $SIGN_IDENTITY..."
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT_DMG"
    codesign --verify --verbose=2 "$OUT_DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "ERROR: Notarizing a DMG requires a valid Developer ID signing identity." >&2
        exit 1
    fi
    echo "Submitting $OUT_DMG to Apple Notary service (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "Stapling notarization ticket to $OUT_DMG..."
    staple_ok=0
    for attempt in 1 2 3 4 5 6; do
        if xcrun stapler staple "$OUT_DMG" && xcrun stapler validate "$OUT_DMG"; then
            staple_ok=1
            break
        fi
        echo "  Stapler attempt $attempt/6 hit transient error; retrying in 5s..."
        sleep 5
    done
    if [ "$staple_ok" -ne 1 ]; then
        echo "ERROR: Failed to staple and validate DMG notarization ticket after 6 attempts." >&2
        exit 68
    fi
    spctl -a -t open --context context:primary-signature -vv "$OUT_DMG"
fi

echo "Created DMG successfully: $OUT_DMG"
