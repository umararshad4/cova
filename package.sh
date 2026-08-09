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

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
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
  echo "built $DMG ($(du -h "$DMG" | cut -f1))"
else
  rm -f "$DMG" "$RAW" "$RAW_IMAGE"
  echo "hdiutil unavailable or hung — skipped the DMG. Install from $ZIP instead." >&2
fi

rm -rf "$STAGE"
