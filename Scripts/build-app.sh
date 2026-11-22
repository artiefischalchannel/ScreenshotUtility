#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ScreenshotUtility"
# CONFIGURATION=debug OUTPUT_DIR=... builds a development copy somewhere other than dist/.
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
PLIST_TEMPLATE="$ROOT_DIR/Resources/Info.plist"
CACHE_DIR="$ROOT_DIR/.build/cache"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
SWIFTPM_HOME_DIR="$ROOT_DIR/.build/swiftpm-home"

mkdir -p "$CACHE_DIR" "$MODULE_CACHE_DIR" "$SWIFTPM_HOME_DIR"
export XDG_CACHE_HOME="$CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_HOME="$SWIFTPM_HOME_DIR"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cp ".build/$CONFIGURATION/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"

# macOS ties Screen Recording and Accessibility permission to the app's signature. An ad-hoc
# signature changes with every build, which silently drops those permissions, so sign with a
# stable development certificate when one is installed. Override with CODESIGN_IDENTITY
# (a certificate name or hash, or "-" to force ad-hoc).
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')"
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] && codesign --force --sign "$IDENTITY" "$APP_DIR" >/dev/null 2>&1; then
  echo "Signed with a stable development certificate; granted permissions survive rebuilds."
else
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
  echo "Signed ad-hoc; macOS will ask for Screen Recording and Accessibility again after each build."
fi
echo "Built $APP_DIR"
