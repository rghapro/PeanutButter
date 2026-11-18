#!/bin/bash
set -euo pipefail

DO_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --notarize)
            DO_NOTARIZE=1
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: ./build.sh [--notarize]" >&2
            exit 1
            ;;
    esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-PeanutButter-Notary}"

echo "Building PeanutButter..."
swift build -c release

echo "Packaging PeanutButter.app..."
rm -rf "PeanutButter.app"
mkdir -p "PeanutButter.app/Contents/MacOS"
mkdir -p "PeanutButter.app/Contents/Resources"
cp "Sources/PeanutButter/Resources/Info.plist" "PeanutButter.app/Contents/Info.plist"
cp ".build/release/PeanutButter" "PeanutButter.app/Contents/MacOS/PeanutButter"
chmod +x "PeanutButter.app/Contents/MacOS/PeanutButter"
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
    rm -rf \
        "$STAGE_DIR/PeanutButter.app/Contents/Resources/Audio/Click" \
        "$STAGE_DIR/PeanutButter.app/Contents/Resources/Audio/Dynamic Cues" \
        "$STAGE_DIR/PeanutButter.app/Contents/Resources/Audio/Song Sections"
    /usr/bin/xattr -cr "$STAGE_DIR/PeanutButter.app"

    echo "Signing staged PeanutButter.app with $SIGN_IDENTITY..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE_DIR/PeanutButter.app"
    codesign --verify --deep --strict --verbose=2 "$STAGE_DIR/PeanutButter.app"

    echo "Creating submission archive..."
    ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR/PeanutButter.app" "$STAGE_DIR/PeanutButter-submit.zip"

    echo "Submitting to Apple Notary service (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$STAGE_DIR/PeanutButter-submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$STAGE_DIR/PeanutButter.app"
    xcrun stapler validate "$STAGE_DIR/PeanutButter.app"
    spctl --assess --type execute --verbose=4 "$STAGE_DIR/PeanutButter.app"

    echo "Packaging notarized PeanutButter.zip..."
    rm -f "PeanutButter.zip"
    ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR/PeanutButter.app" "PeanutButter.zip"
fi

echo "Build and packaging successful! You can now launch 'PeanutButter.app' or run 'open \"PeanutButter.app\"'."
