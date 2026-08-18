#!/bin/bash
# Builds a release Tyland.app and packages it for installation.
#
# Produces build/Tyland.zip always, and build/Tyland.dmg when hdiutil is healthy.
# The ZIP is the reliable artefact: `hdiutil` has to attach a temporary volume, which can hang
# indefinitely if DiskArbitration is wedged or a "Removable Volumes" consent prompt is pending.
# ditto preserves code signatures and symlinks, so a ZIP installs identically — drag to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Tyland.app"
STAGE="$ROOT/build/dmg"
DMG="$ROOT/build/Tyland.dmg"
RAW="$ROOT/build/Tyland.raw"
RAW_IMAGE="$RAW.iso"
ZIP="$ROOT/build/Tyland.zip"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist" 2>/dev/null || echo "0.1.0")

"$ROOT/build.sh" release

# The helper must keep its own signing identifier — `codesign --deep` on the app would clobber it,
# and Now Playing silently dies if it does.
HELPER_ID=$(codesign -d --verbose=2 "$APP/Contents/Helpers/TylandHelper" 2>&1 | sed -n 's/^Identifier=//p')
if [ "$HELPER_ID" != "com.apple.tyland.mediahelper" ]; then
  echo "helper identifier is '$HELPER_ID', expected com.apple.tyland.mediahelper" >&2
  exit 1
fi

# Are we producing something a stranger can actually install?
SIGNED=0
if codesign -d --verbose=2 "$APP" 2>&1 | grep -q "^TeamIdentifier=[A-Z0-9]"; then
  SIGNED=1
fi

# --- notarization ------------------------------------------------------------
# Gatekeeper quarantines any download that is not notarized *and* stapled. Without this a paying
# customer sees "Apple could not verify Tyland is free of malware" and has to be talked through
# System Settings — the right-click-Open shortcut no longer exists on macOS 15+.
#
# Needs an App Store Connect API key: NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH.
notarize() {
  local artifact="$1"
  if [ "$SIGNED" -eq 0 ]; then return 0; fi
  if [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER_ID:-}" ] || [ -z "${NOTARY_KEY_PATH:-}" ]; then
    echo "error: signed build with no notarization credentials — refusing to ship an unstapled artifact" >&2
    exit 1
  fi
  echo "notarizing $(basename "$artifact")…"
  # `--wait` can sit for hours during an Apple notary outage, so bound it. Publishing nothing beats
  # publishing something Gatekeeper will reject.
  if ! xcrun notarytool submit "$artifact" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" \
        --wait --timeout "${NOTARY_TIMEOUT:-45m}"; then
    echo "error: notarization failed or timed out" >&2
    exit 1
  fi
}

rm -f "$ZIP"
# A ZIP cannot be stapled, so the *app* is notarized and stapled first and then re-zipped.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
notarize "$ZIP"
if [ "$SIGNED" -eq 1 ]; then
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "stapled $APP"
else
  echo "warning: ad-hoc signed. This artifact is for local use only — Gatekeeper will block it" >&2
  echo "         for anyone who downloads it. Set TYLAND_SIGN_IDENTITY to build for distribution." >&2
fi
echo "built $ZIP ($(du -h "$ZIP" | cut -f1))"

# --- DMG, best effort -------------------------------------------------------
rm -rf "$STAGE" "$DMG" "$RAW" "$RAW_IMAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# macOS does not ship GNU `timeout`; run the non-attaching hdiutil commands with a tiny
# shell watchdog so a wedged DiskArbitration service cannot hang the release job forever.
run_with_timeout() {
  local seconds="$1"; shift
  "$@" &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$seconds" -le 0 ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    seconds=$((seconds - 1))
  done
  wait "$pid"
}

# A pure UDF image preserves code signatures. HFS adds FinderInfo xattrs to nested executables,
# which makes `codesign --verify` reject an otherwise valid app after mounting the DMG.
# makehybrid + convert never attach a volume, unlike `hdiutil create -srcfolder`.
if run_with_timeout 120 hdiutil makehybrid -udf -udf-volume-name "Tyland $VERSION" \
     -o "$RAW" "$STAGE" -quiet 2>/dev/null \
   && run_with_timeout 120 hdiutil convert "$RAW_IMAGE" -format UDZO -o "$DMG" -quiet 2>/dev/null; then
  rm -f "$RAW_IMAGE"
  if [ "$SIGNED" -eq 1 ]; then
    codesign --force --sign "$TYLAND_SIGN_IDENTITY" --timestamp "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
  echo "built $DMG ($(du -h "$DMG" | cut -f1))"
else
  rm -f "$DMG" "$RAW" "$RAW_IMAGE"
  # Best-effort was fine while this was a hobby build. A Homebrew cask pins a DMG URL and its
  # sha256, so a silently missing DMG becomes a broken install for every new user.
  echo "error: DMG creation failed (hdiutil unavailable or hung)" >&2
  if [ "$SIGNED" -eq 1 ]; then exit 1; fi
  echo "       continuing because this is an unsigned local build; install from $ZIP" >&2
fi

rm -rf "$STAGE"
