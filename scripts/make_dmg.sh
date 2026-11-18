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
BG_FILENAME=""
if [ -f "$BG_IMAGE" ]; then
    mkdir -p "$DMG_STAGE/.background"
    if command -v sips >/dev/null 2>&1 && command -v tiffutil >/dev/null 2>&1; then
        sips -z 400 600 -s dpiWidth 72 -s dpiHeight 72 "$BG_IMAGE" --out "$TMP_WORK/bg_1x.png" >/dev/null
        cp "$BG_IMAGE" "$TMP_WORK/bg_2x.png"
        sips -s dpiWidth 144 -s dpiHeight 144 "$TMP_WORK/bg_2x.png" >/dev/null
        tiffutil -cathidpicheck "$TMP_WORK/bg_1x.png" "$TMP_WORK/bg_2x.png" -out "$DMG_STAGE/.background/background.tiff" >/dev/null
        BG_FILENAME="background.tiff"
    else
        cp "$BG_IMAGE" "$DMG_STAGE/.background/background.png"
        BG_FILENAME="background.png"
    fi
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
if ! osascript - "$MOUNT_VOL_NAME" "$HAS_BG" "$BG_FILENAME" <<'APPLESCRIPT'
on run argv
    set volName to item 1 of argv
    set hasBg to (item 2 of argv) as integer
    set bgFilename to item 3 of argv
    tell application "Finder"
        tell disk volName
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set sidebar width of container window to 0
            set the bounds of container window to {200, 120, 800, 548}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 108
            set text size of viewOptions to 12
            if hasBg = 1 then
                set background picture of viewOptions to file (".background:" & bgFilename)
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

if command -v python3 >/dev/null 2>&1 && [ -f "$MOUNT_DIR/.DS_Store" ]; then
    python3 - "$MOUNT_DIR/.DS_Store" <<'PYTHON'
import plistlib
import struct
import sys

ds_path = sys.argv[1]
raw = bytearray(open(ds_path, "rb").read())

if len(raw) < 36 or raw[0:8] != b"\x00\x00\x00\x01Bud1":
    print(f"WARNING: Unexpected .DS_Store header in {ds_path}; leaving untouched.")
    sys.exit(0)

root_off, root_size, root_off2 = struct.unpack(">III", raw[8:20])
if root_off != root_off2:
    print("WARNING: .DS_Store root offsets mismatch; leaving untouched.")
    sys.exit(0)

root = bytes(raw[4 + root_off : 4 + root_off + root_size])
num_blocks = struct.unpack(">I", root[0:4])[0]
padded = ((num_blocks + 255) // 256) * 256
block_addrs = struct.unpack(f">{num_blocks}I", root[8 : 8 + 4 * num_blocks])

pos = 8 + 4 * padded
toc_count = struct.unpack(">I", root[pos : pos + 4])[0]
pos += 4
toc = {}
for _ in range(toc_count):
    nlen = root[pos]
    pos += 1
    tname = root[pos : pos + nlen].decode("ascii")
    pos += nlen
    bid = struct.unpack(">I", root[pos : pos + 4])[0]
    pos += 4
    toc[tname] = bid

if "DSDB" not in toc:
    print("WARNING: DSDB directory missing from .DS_Store; leaving untouched.")
    sys.exit(0)

def get_block(bid):
    addr = block_addrs[bid]
    bsize = 1 << (addr & 0x1F)
    boff = 4 + (addr & ~0x1F)
    return boff, bsize

dsdb_off, _ = get_block(toc["DSDB"])
root_node, levels, rec_count, node_count, page_size = struct.unpack(
    ">IIIII", raw[dsdb_off : dsdb_off + 20]
)
if levels != 0:
    print(f"WARNING: .DS_Store B-tree has levels={levels} (expected 0); leaving untouched.")
    sys.exit(0)

leaf_off, leaf_size = get_block(root_node)
p, count = struct.unpack(">II", raw[leaf_off : leaf_off + 8])
if p != 0:
    print(f"WARNING: .DS_Store root node has P={p} (expected leaf P=0); leaving untouched.")
    sys.exit(0)

records = []
rpos = leaf_off + 8
for _ in range(count):
    namelen = struct.unpack(">I", raw[rpos : rpos + 4])[0]
    rpos += 4
    name_bytes = bytes(raw[rpos : rpos + namelen * 2])
    name = name_bytes.decode("utf-16-be")
    rpos += namelen * 2
    rec_type = bytes(raw[rpos : rpos + 4]).decode("ascii")
    data_type = bytes(raw[rpos + 4 : rpos + 8]).decode("ascii")
    rpos += 8

    if data_type == "blob":
        blen = struct.unpack(">I", raw[rpos : rpos + 4])[0]
        rpos += 4
        payload = bytes(raw[rpos : rpos + blen])
        rpos += blen
    elif data_type in ("long", "shor", "type"):
        payload = bytes(raw[rpos : rpos + 4])
        rpos += 4
    elif data_type == "bool":
        payload = bytes(raw[rpos : rpos + 1])
        rpos += 1
    elif data_type in ("comp", "dutc"):
        payload = bytes(raw[rpos : rpos + 8])
        rpos += 8
    elif data_type == "ustr":
        ulen = struct.unpack(">I", raw[rpos : rpos + 4])[0]
        rpos += 4
        payload = bytes(raw[rpos : rpos + ulen * 2])
        rpos += ulen * 2
    else:
        print(f"WARNING: Unsupported .DS_Store record type '{data_type}'; leaving untouched.")
        sys.exit(0)

    records.append([namelen, name_bytes, name, rec_type, data_type, payload])

updated_bwsp = False
updated_icvp = False
for rec in records:
    _, _, name, rec_type, data_type, payload = rec
    if name == "." and rec_type == "bwsp" and data_type == "blob":
        rec[5] = plistlib.dumps(
            {
                "ContainerShowSidebar": False,
                "ShowPathbar": False,
                "ShowSidebar": False,
                "ShowStatusBar": False,
                "ShowTabView": False,
                "ShowToolbar": False,
                "WindowBounds": "{{200, 220}, {600, 428}}",
            },
            fmt=plistlib.FMT_BINARY,
        )
        updated_bwsp = True
    elif name == "." and rec_type == "icvp" and data_type == "blob":
        icvp = plistlib.loads(payload)
        icvp["backgroundColorRed"] = 0.945
        icvp["backgroundColorGreen"] = 0.949
        icvp["backgroundColorBlue"] = 0.961
        rec[5] = plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)
        updated_icvp = True

out_leaf = bytearray(struct.pack(">II", 0, count))
for namelen, name_bytes, _, rec_type, data_type, payload in records:
    out_leaf.extend(struct.pack(">I", namelen))
    out_leaf.extend(name_bytes)
    out_leaf.extend(rec_type.encode("ascii"))
    out_leaf.extend(data_type.encode("ascii"))
    if data_type == "blob":
        out_leaf.extend(struct.pack(">I", len(payload)))
        out_leaf.extend(payload)
    elif data_type == "ustr":
        out_leaf.extend(struct.pack(">I", len(payload) // 2))
        out_leaf.extend(payload)
    else:
        out_leaf.extend(payload)

if len(out_leaf) > leaf_size:
    print(f"WARNING: Normalized leaf ({len(out_leaf)} B) exceeds page size ({leaf_size} B); leaving untouched.")
    sys.exit(0)

out_leaf.extend(b"\x00" * (leaf_size - len(out_leaf)))
raw[leaf_off : leaf_off + leaf_size] = out_leaf
with open(ds_path, "wb") as f:
    f.write(raw)
print(f"Normalized .DS_Store (bwsp={updated_bwsp}, icvp={updated_icvp}).")
PYTHON
    sync
    sleep 1
fi

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
