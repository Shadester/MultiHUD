#!/bin/bash
# deploy.sh — build, notarize, staple, and install MultiHUD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KEYCHAIN_PROFILE="MultiHUD"
APP_NAME="MultiHUD"
SCHEME="MultiHUD"
CONFIGURATION="Release"

BUILD_DIR="$PROJECT_DIR/.build"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"

echo "==> Generating Xcode project..."
xcodegen generate

VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")
echo "==> Building $SCHEME ($CONFIGURATION) version $VERSION..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR/xcode" \
  SYMROOT="$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" \
  build

APP_PATH="$BUILD_DIR/$CONFIGURATION/$APP_NAME.app"

echo "==> Verifying signature..."
codesign --verify --deep --strict "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep "Authority" | head -1

echo "==> Creating ZIP for notarization..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting for notarization (may take a few minutes)..."
RESULT=$(xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait --output-format json)

echo "$RESULT"
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")

if [ "$STATUS" != "Accepted" ]; then
  ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo "Notarization failed ($STATUS). Fetching log..."
  xcrun notarytool log "$ID" --keychain-profile "$KEYCHAIN_PROFILE"
  exit 1
fi

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "==> Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
ditto "$APP_PATH" "/Applications/$APP_NAME.app"

echo "==> Done. Launching MultiHUD..."
pkill -x MultiHUD 2>/dev/null || true
pkill -KILL -x MultiHUD 2>/dev/null || true
sleep 1
open /Applications/MultiHUD.app
