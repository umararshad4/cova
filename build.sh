#!/bin/bash
# Builds Tyland.app with the Command Line Tools toolchain. Xcode not required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Tyland.app"
MODE="${1:-debug}"

case "$MODE" in
  release) OPT=(-O -whole-module-optimization) ;;
  debug)   OPT=(-Onone -g) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# ponytail: plain find over Sources instead of an SPM manifest or .xcodeproj.
# Move to SPM when we need external packages or incremental builds.
# No mapfile here — macOS ships bash 3.2. Source paths never contain spaces.
SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)

swiftc -target arm64-apple-macos14.0 "${OPT[@]}" \
  -o "$APP/Contents/MacOS/Tyland" $SOURCES

# Media helper. Built and signed separately because mediaremoted decides whether to answer based
# on the *code signing identifier* — it grants access to anything under com.apple.*. Signing this
# binary as com.apple.tyland.mediahelper is what buys us Now Playing on macOS 15.4+.
mkdir -p "$APP/Contents/Helpers"
swiftc -target arm64-apple-macos14.0 "${OPT[@]}" \
  -o "$APP/Contents/Helpers/TylandHelper" "$ROOT/Helper/main.swift"
codesign --force --sign - --identifier com.apple.tyland.mediahelper "$APP/Contents/Helpers/TylandHelper"

# Sign the app last, and without --deep, so the helper keeps its own identifier.
codesign --force --sign - "$APP"
echo "built $APP ($MODE, $(echo "$SOURCES" | wc -l | tr -d ' ') sources)"
