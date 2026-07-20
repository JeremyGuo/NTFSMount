#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="NTFSMount"
HELPER_NAME="NTFSMountHelper"
HELPER_LABEL="com.gjy.NTFSMount.Helper"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP="$DIST_DIR/$APP_NAME.app"

cd "$ROOT"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c "$CONFIGURATION"
    BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
fi

"$ROOT/Scripts/create-icns.sh" "$ROOT/Resources/AppIcon.png" "$ROOT/Resources/AppIcon.icns" >/dev/null

rm -rf "$APP"
mkdir -p \
    "$APP/Contents/MacOS" \
    "$APP/Contents/Resources" \
    "$APP/Contents/Library/LaunchDaemons" \
    "$APP/Contents/Library/LaunchServices"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$HELPER_NAME" "$APP/Contents/Library/LaunchServices/$HELPER_LABEL"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/DriverAllowlist.plist" "$APP/Contents/Resources/DriverAllowlist.plist"
cp "$ROOT/Resources/$HELPER_LABEL.plist" "$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --identifier "$HELPER_LABEL" \
        --sign "$SIGN_IDENTITY" \
        "$APP/Contents/Library/LaunchServices/$HELPER_LABEL"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP"
else
    /usr/bin/codesign \
        --force \
        --identifier "$HELPER_LABEL" \
        --sign - \
        "$APP/Contents/Library/LaunchServices/$HELPER_LABEL"
    /usr/bin/codesign --force --sign - "$APP"
fi

/usr/bin/codesign --verify --deep --strict "$APP"
echo "$APP"
