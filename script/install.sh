#!/usr/bin/env bash
set -euo pipefail

# Builds OpenUsage from source and installs it into /Applications as a normal, signed app — so this
# fork becomes your everyday OpenUsage without re-running build_and_run.sh each session.
#
# How it differs from build_and_run.sh (the dev runner):
#   - installs to /Applications/OpenUsage.app instead of launching from dist/ in place;
#   - uses the production bundle id (com.robinebers.openusage) by default, so it inherits your existing
#     OpenUsage settings, menu-bar layout, and permission grants and replaces the released app;
#   - stamps a real version derived from the latest git tag (with a +local suffix) instead of "-dev".
#
# It ships NO Sparkle feed, so the installed app never auto-updates back to an upstream release and
# silently drops your fork's changes. Re-run this script whenever you want to pick up new commits.
#
# Usage: script/install.sh [install|build]      (default: install — build, stage, copy, launch)
# Env:   BUNDLE_ID          override bundle id (e.g. com.robinebers.openusage.fork for side-by-side)
#        APP_DISPLAY        override app name (default OpenUsage)
#        CODESIGN_IDENTITY  override signing identity (exact name or hash)
#        CONFIG             "release" (default) or "debug"

MODE="${1:-install}"
CONFIG="${CONFIG:-release}"

TARGET_NAME="OpenUsage"                  # SwiftPM target / binary name
APP_DISPLAY="${APP_DISPLAY:-OpenUsage}"  # user-facing app name
BUNDLE_ID="${BUNDLE_ID:-com.robinebers.openusage}"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve a human version, marked +local so it's never mistaken for an official release. Prefer the
# latest git tag (e.g. v0.7.1-beta.3); fall back to the top version heading in CHANGELOG.md (this fork
# carries no tags), then to 0.0.0. CFBundleVersion uses the commit count as a monotonic build number.
# `|| true` keeps a tagless repo (git describe exits 128) from tripping `set -e` / `pipefail`.
BASE_VERSION="$( { git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true; } | sed 's/^v//')"
if [ -z "$BASE_VERSION" ]; then
  BASE_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?' "$ROOT_DIR/CHANGELOG.md" 2>/dev/null | head -1)"
fi
APP_VERSION="${BASE_VERSION:-0.0.0}+local"
APP_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$TARGET_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
# The dev entitlements carry iCloud keys that only launch with a matching provisioning profile; this
# install embeds none, so it signs without them and iCloud Sync stays off.
ENTITLEMENTS="$ROOT_DIR/script/OpenUsage.local.entitlements.plist"
INSTALL_PATH="/Applications/$APP_DISPLAY.app"

pkill -x "$TARGET_NAME" >/dev/null 2>&1 || true

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$TARGET_NAME"

if [ ! -x "$BUILD_BINARY" ]; then
  echo "missing built binary: $BUILD_BINARY" >&2
  exit 1
fi

echo "==> staging $APP_BUNDLE ($APP_VERSION, build $APP_BUILD, id $BUNDLE_ID)"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# SwiftPM stamps LC_BUILD_VERSION's `sdk` field with the deployment target (macOS 15), not the real SDK
# it compiled against. macOS gates the modern Liquid Glass control appearance on the linked SDK, so a
# "15.0" stamp falls back to legacy Aqua controls. Restamp the sdk to 26.0 (Tahoe) while keeping minos
# at MIN_SYSTEM_VERSION so the app still runs on macOS 15 but gets the modern controls. Re-signed below.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Stage every SwiftPM resource bundle (the app's OpenUsage_OpenUsage.bundle with provider SVGs + model
# manifest) into Contents/Resources. Bundle.openUsageResources loads it from there.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Compile the Icon Composer source into Assets.car so Tahoe renders the real Liquid Glass icon.
# CFBundleIconName below must match the .icon file stem ("AppIcon"). Falls back to the committed
# prebuilt icon when actool is broken on the toolchain (same path release CI uses).
echo "==> compiling app icon (actool)"
PREBUILT_ICON_DIR="$ROOT_DIR/assets/AppIcon.prebuilt"
if xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --output-partial-info-plist /dev/null \
  --output-format human-readable-text --errors --warnings; then
  : # compiled the icon fresh
elif [ -f "$PREBUILT_ICON_DIR/Assets.car" ]; then
  echo "==> actool failed; using prebuilt icon (assets/AppIcon.prebuilt)"
  cp "$PREBUILT_ICON_DIR/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$PREBUILT_ICON_DIR/AppIcon.icns" ] && cp "$PREBUILT_ICON_DIR/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "WARNING: actool failed and no prebuilt icon found; continuing without an icon" >&2
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$TARGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Pick a stable Apple Development identity so ad-hoc cdhash churn doesn't re-trigger permission prompts
# on every rebuild. Fall back to ad-hoc only if none is found.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development:/ { print $2; exit }')
fi

# Embed + sign Sparkle.framework before sealing the app. The executable links Sparkle, so without the
# embedded framework the build won't launch — even though the updater stays dormant (no SUFeedURL above).
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "--options runtime"

if [ -n "$CODESIGN_IDENTITY" ]; then
  # Not --deep: the Sparkle framework is already signed above and must keep that signature.
  /usr/bin/codesign --force --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE" >/dev/null
  echo "==> signed with: $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  echo "WARNING: no Apple Development identity found; ad-hoc signed." >&2
fi

if [ "$MODE" = "build" ]; then
  echo "==> staged $APP_BUNDLE (not installed; MODE=build)"
  exit 0
fi

echo "==> installing to $INSTALL_PATH"
rm -rf "$INSTALL_PATH"
# ditto preserves the signed bundle (extended attributes, symlinks) exactly, unlike a plain cp -R.
/usr/bin/ditto "$APP_BUNDLE" "$INSTALL_PATH"

echo "==> launching $APP_DISPLAY"
/usr/bin/open "$INSTALL_PATH"
echo "==> done: $INSTALL_PATH ($APP_VERSION)"
