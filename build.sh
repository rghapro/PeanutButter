#!/bin/bash
set -euo pipefail

DO_NOTARIZE=0
NATIVE_ONLY=0
DO_DMG=0
for arg in "$@"; do
    case "$arg" in
        --notarize)
            DO_NOTARIZE=1
            ;;
        --native-only)
            NATIVE_ONLY=1
            ;;
        --dmg)
            DO_DMG=1
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: ./build.sh [--notarize] [--native-only] [--dmg]" >&2
            exit 1
            ;;
    esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-PeanutButter-Notary}"
if [ "$NATIVE_ONLY" -eq 1 ]; then
    echo "Building PeanutButter (native architecture only)..."
    swift build -c release
    NATIVE_BIN_DIR=$(swift build -c release --show-bin-path)
else
    echo "Building PeanutButter (Universal: arm64 + x86_64)..."
    echo "  -> Building arm64 slice..."
    swift build -c release --arch arm64
    ARM64_BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

    echo "  -> Building x86_64 slice..."
    swift build -c release --arch x86_64
    X86_64_BIN_DIR=$(swift build -c release --arch x86_64 --show-bin-path)
fi

echo "Packaging PeanutButter.app..."
rm -rf "PeanutButter.app"
mkdir -p "PeanutButter.app/Contents/MacOS"
mkdir -p "PeanutButter.app/Contents/Resources"
cp "Sources/PeanutButter/Resources/Info.plist" "PeanutButter.app/Contents/Info.plist"
if [ "$NATIVE_ONLY" -eq 1 ]; then
    cp "$NATIVE_BIN_DIR/PeanutButter" "PeanutButter.app/Contents/MacOS/PeanutButter"
else
    /usr/bin/lipo -create -output "PeanutButter.app/Contents/MacOS/PeanutButter" \
        "$ARM64_BIN_DIR/PeanutButter" \
        "$X86_64_BIN_DIR/PeanutButter"
fi
chmod +x "PeanutButter.app/Contents/MacOS/PeanutButter"

BUILT_ARCHS=$(lipo -archs "PeanutButter.app/Contents/MacOS/PeanutButter")
echo "Built binary architectures: $BUILT_ARCHS"
if [ "$NATIVE_ONLY" -eq 0 ]; then
    case " $BUILT_ARCHS " in
        *" arm64 "*) ;;
        *) echo "ERROR: Missing arm64 slice in universal binary" >&2; exit 1 ;;
    esac
    case " $BUILT_ARCHS " in
        *" x86_64 "*) ;;
        *) echo "ERROR: Missing x86_64 slice in universal binary" >&2; exit 1 ;;
    esac
fi
cp -R Sources/PeanutButter/Resources/* "PeanutButter.app/Contents/Resources/" 2>/dev/null || true
rm -f "PeanutButter.app/Contents/Resources/Info.plist"
/usr/bin/xattr -cr "PeanutButter.app"

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing PeanutButter.app with $SIGN_IDENTITY..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "PeanutButter.app"
else
    echo "Signing PeanutButter.app (ad-hoc fallback; no Developer ID Application certificate found)..."
    codesign --force --deep --sign - "PeanutButter.app"
fi

codesign --verify --deep --strict "PeanutButter.app"

strip_nonredistributable_audio() {
    local app_bundle="$1"
    local audio_res="$app_bundle/Contents/Resources/Audio"
    rm -rf \
        "$audio_res/Click" \
        "$audio_res/Dynamic Cues" \
        "$audio_res/Song Sections" \
        "$audio_res/Guides/Rita"
    if [ -d "$audio_res/Pads" ]; then
        for pad_dir in "$audio_res/Pads"/*; do
            [ -d "$pad_dir" ] || continue
            local base
            base=$(basename "$pad_dir")
            if [ "$base" != "Simple" ] && [ "$base" != "Soft" ]; then
                rm -rf "$pad_dir"
            fi
        done
    fi
}

if [ "$DO_NOTARIZE" -eq 1 ]; then
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "ERROR: --notarize requires a Developer ID Application certificate in your Keychain (or CODESIGN_IDENTITY env var)." >&2
        exit 1
    fi

    echo "Staging clean distribution bundle for Apple Notarization..."
    STAGE_DIR=$(mktemp -d /tmp/pb_notarize.XXXXXX)
    cleanup_stage() {
        rm -rf "$STAGE_DIR"
    }
    trap cleanup_stage EXIT

    ditto "PeanutButter.app" "$STAGE_DIR/PeanutButter.app"
    strip_nonredistributable_audio "$STAGE_DIR/PeanutButter.app"
    /usr/bin/xattr -cr "$STAGE_DIR/PeanutButter.app"

    echo "Signing staged PeanutButter.app with $SIGN_IDENTITY..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE_DIR/PeanutButter.app"
    codesign --verify --deep --strict --verbose=2 "$STAGE_DIR/PeanutButter.app"

    echo "Creating submission archive..."
    ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR/PeanutButter.app" "$STAGE_DIR/PeanutButter-submit.zip"

    echo "Submitting to Apple Notary service (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$STAGE_DIR/PeanutButter-submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "Stapling notarization ticket..."
    staple_ok=0
    for attempt in 1 2 3 4 5 6; do
        if xcrun stapler staple "$STAGE_DIR/PeanutButter.app" && xcrun stapler validate "$STAGE_DIR/PeanutButter.app"; then
            staple_ok=1
            break
        fi
        echo "  Stapler attempt $attempt/6 hit transient error; retrying in 5s..."
        sleep 5
    done
    if [ "$staple_ok" -ne 1 ]; then
        echo "ERROR: Failed to staple and validate notarization ticket after 6 attempts." >&2
        exit 68
    fi
    spctl --assess --type execute --verbose=4 "$STAGE_DIR/PeanutButter.app"

    echo "Packaging notarized PeanutButter.zip..."
    rm -f "PeanutButter.zip"
    ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR/PeanutButter.app" "PeanutButter.zip"

    echo "Packaging and notarizing PeanutButter.dmg..."
    chmod +x "./scripts/make_dmg.sh"
    ./scripts/make_dmg.sh "$STAGE_DIR/PeanutButter.app" "PeanutButter.dmg" "$SIGN_IDENTITY" "$NOTARY_PROFILE"
elif [ "$DO_DMG" -eq 1 ]; then
    echo "Staging clean bundle and packaging PeanutButter.dmg..."
    STAGE_DIR=$(mktemp -d /tmp/pb_dmg_stage.XXXXXX)
    cleanup_dmg_stage() {
        rm -rf "$STAGE_DIR"
    }
    trap cleanup_dmg_stage EXIT

    ditto "PeanutButter.app" "$STAGE_DIR/PeanutButter.app"
    strip_nonredistributable_audio "$STAGE_DIR/PeanutButter.app"
    /usr/bin/xattr -cr "$STAGE_DIR/PeanutButter.app"
    if [ -n "$SIGN_IDENTITY" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE_DIR/PeanutButter.app"
    else
        codesign --force --deep --sign - "$STAGE_DIR/PeanutButter.app"
    fi
    codesign --verify --deep --strict "$STAGE_DIR/PeanutButter.app"

    chmod +x "./scripts/make_dmg.sh"
    ./scripts/make_dmg.sh "$STAGE_DIR/PeanutButter.app" "PeanutButter.dmg" "$SIGN_IDENTITY"
fi

echo "Build and packaging successful! You can now launch 'PeanutButter.app' or run 'open \"PeanutButter.app\"'."
