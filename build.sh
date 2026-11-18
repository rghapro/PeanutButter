#!/bin/bash
set -e

echo "Building PeanutButter..."
swift build -c release

echo "Packaging PeanutButter.app..."
mkdir -p "PeanutButter.app/Contents/MacOS"
mkdir -p "PeanutButter.app/Contents/Resources"
cp Sources/PeanutButter/Resources/Info.plist "PeanutButter.app/Contents/Info.plist"
cp .build/release/PeanutButter "PeanutButter.app/Contents/MacOS/PeanutButter"
chmod +x "PeanutButter.app/Contents/MacOS/PeanutButter"
cp -R Sources/PeanutButter/Resources/* "PeanutButter.app/Contents/Resources/" 2>/dev/null || true
codesign --force --deep --sign - "PeanutButter.app" 2>/dev/null || true

echo "Build and packaging successful! You can now launch 'PeanutButter.app' or run 'open \"PeanutButter.app\"'."
