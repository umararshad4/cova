#!/bin/bash
# Builds Tyland.app with the Command Line Tools toolchain. Xcode not required.
#
# Signing has two modes:
#   dev      (default)  ad-hoc, fast, single-architecture — what you want while iterating.
#   release            Developer ID + hardened runtime + secure timestamp + entitlements, and a
#                      universal binary, which is what a paying customer must receive.
#
# Set TYLAND_SIGN_IDENTITY to a "Developer ID Application: …" identity to sign for real. Without it
# a release build still works, but stays ad-hoc — and package.sh will refuse to notarize it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Tyland.app"
MODE="${1:-debug}"

# macOS 13.0 is the floor. Only the CoreAudio process tap needs anything newer, and it already
# carries its own `if #available(macOS 14.4, *)` guard — so the waveform degrades on older systems
# instead of excluding them. "Works on every Mac" has to survive contact with the deployment target.
DEPLOYMENT_TARGET="13.0"

case "$MODE" in
  release) OPT=(-O -whole-module-optimization); ARCHS=(arm64 x86_64) ;;
  debug)   OPT=(-Onone -g);                     ARCHS=(arm64) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

# Machine check: an assert-based self-test is compiled out at -O, so the release binary must keep
# `precondition`. SelfTest.swift uses precondition for exactly that reason — see scripts/checks.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# ponytail: plain find over Sources instead of an SPM manifest or .xcodeproj.
# Move to SPM when we need external packages or incremental builds.
# No mapfile here — macOS ships bash 3.2. Source paths never contain spaces.
SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)

# Builds one architecture of one target into $3.
build_slice() {
  local arch="$1" out="$2"; shift 2
  swiftc -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" "${OPT[@]}" -o "$out" "$@"
}

# Universal only in release: cross-compiling doubles an already 16-second debug build for nothing.
# The desktop and external-display segment the app is positioned at skews Intel, so shipping
# arm64-only would make the headline claim false at the point of sale.
build_universal() {
  local out="$1"; shift
  if [ "${#ARCHS[@]}" -eq 1 ]; then
    build_slice "${ARCHS[0]}" "$out" "$@"
    return
  fi
  local slices=()
  for arch in "${ARCHS[@]}"; do
    build_slice "$arch" "$out.$arch" "$@"
    slices+=("$out.$arch")
  done
  lipo -create -output "$out" "${slices[@]}"
  rm -f "${slices[@]}"
}

build_universal "$APP/Contents/MacOS/Tyland" $SOURCES

# Media helper. Built and signed separately because mediaremoted decides whether to answer based
# on the *code signing identifier* — it grants access to anything under com.apple.*. Signing this
# binary as com.apple.tyland.mediahelper is what buys us Now Playing on macOS 15.4+.
mkdir -p "$APP/Contents/Helpers"
build_universal "$APP/Contents/Helpers/TylandHelper" "$ROOT/Helper/main.swift"

# --- signing ----------------------------------------------------------------
# Inside-out and never --deep: the helper keeps its own identifier, which package.sh asserts.
IDENTITY="${TYLAND_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  # Hardened runtime and a secure timestamp are both notarization requirements.
  SIGN_ARGS+=(--options runtime --timestamp)
else
  echo "warning: ad-hoc signing (set TYLAND_SIGN_IDENTITY for a distributable build)" >&2
fi

codesign "${SIGN_ARGS[@]}" --identifier com.apple.tyland.mediahelper "$APP/Contents/Helpers/TylandHelper"
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/Resources/Tyland.entitlements" "$APP"

echo "built $APP ($MODE, $(echo "$SOURCES" | wc -l | tr -d ' ') sources, ${ARCHS[*]}, identity ${IDENTITY})"
