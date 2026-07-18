#!/bin/bash
# WindowPilot release pipeline:
#   build → assemble bundle → sign (inner-first) → DMG → notarize → staple
#   → generate appcast (EdDSA) → commit appcast + upload GitHub release
#
# Usage:   scripts/release.sh <version> [release-notes.html]
# Env:     FEED_URL              override SUFeedURL (default: GitHub raw appcast)
#          DOWNLOAD_URL_PREFIX   override enclosure URL prefix (default: GitHub release)
#          SKIP_NOTARIZE=1       skip notarization+staple (local testing only)
#          DRY_RUN=1             skip git push + gh release (local testing only)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [notes.html]}"
NOTES_HTML="${2:-}"
FEED_URL="${FEED_URL:-https://raw.githubusercontent.com/ethannortharc/WindowPilot/main/appcast.xml}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/ethannortharc/WindowPilot/releases/download/v${VERSION}/}"
IDENTITY="Developer ID Application: HONGBO ZHOU (SBU743JJ9S)"
APP="WindowPilot.app"
DMG="WindowPilot-${VERSION}.dmg"
ARCHIVE_DIR="release-archive"
PUBKEY="$(cat scripts/sparkle_public_key.txt)"
# EdDSA private key: exported file (headless-friendly; Keychain ACL blocks
# generate_appcast in non-interactive shells). Falls back to Keychain lookup.
ED_KEY_FILE="${ED_KEY_FILE:-$HOME/.config/windowpilot/sparkle_ed25519_key}"

# Never publish an un-notarized build.
if [ "${SKIP_NOTARIZE:-0}" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
  echo "SKIP_NOTARIZE=1 requires DRY_RUN=1 — un-notarized builds must not be published" >&2
  exit 1
fi

# --- 1. Build (also materializes Package.resolved on a fresh clone)
sed -i '' "s/let cliVersion = \".*\"/let cliVersion = \"${VERSION}\"/" Sources/CLI/Version.swift
# Commit the stamped version BEFORE building, so the commit that later gets
# pushed and tagged carries the version it ships (mirrors the appcast-commit
# precedent below). Guard on an actual diff — an unconditional commit would
# abort the whole release under set -e on a re-run with an unchanged version.
VERSION_STAMPED=0
if ! git diff --quiet -- Sources/CLI/Version.swift; then
  VERSION_STAMPED=1
  if [ "${DRY_RUN:-0}" != "1" ]; then
    git add Sources/CLI/Version.swift
    git commit -m "Stamp CLI version ${VERSION}"
  fi
fi
swift build -c release
# DRY_RUN never commits (see above) — restore the working tree here instead,
# AFTER the build so the binary still gets the stamped version in dry runs.
if [ "${DRY_RUN:-0}" = "1" ] && [ "$VERSION_STAMPED" = "1" ]; then
  git checkout -- Sources/CLI/Version.swift
fi

# --- 1b. Sparkle command-line tools (cached, version-matched to Package.resolved)
SPARKLE_VERSION=$(python3 -c "import json;print([p for p in json.load(open('Package.resolved'))['pins'] if p['identity']=='sparkle'][0]['state']['version'])")
TOOLS=".build/sparkle-dist/bin"
if [ ! -x "$TOOLS/generate_appcast" ]; then
  mkdir -p .build/sparkle-dist
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" | tar -xJ -C .build/sparkle-dist
fi

# --- 2. Assemble bundle (updates the existing WindowPilot.app in place;
#         Resources/ with the app icon is preserved)
cp .build/release/WindowPilot "$APP/Contents/MacOS/WindowPilot"
cp .build/release/windowpilot-cli "$APP/Contents/MacOS/windowpilot-cli"
FRAMEWORK_SRC=$(find .build/artifacts -type d -name "Sparkle.framework" | head -1)
[ -n "$FRAMEWORK_SRC" ] || { echo "Sparkle.framework not found in .build/artifacts" >&2; exit 1; }
rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/"

# --- 3. Info.plist (regenerated every release — single source of truth)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>WindowPilot</string>
    <key>CFBundleExecutable</key><string>WindowPilot</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.windowpilot.app</string>
    <key>CFBundleName</key><string>WindowPilot</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>${FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${PUBKEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# --- 4. Codesign, inner-first (Sparkle helpers must be signed or notarization fails)
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW"
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/windowpilot-cli"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

# --- 5. DMG
rm -f "$DMG"
hdiutil create -volname "WindowPilot" -srcfolder "$APP" -ov -format UDZO "$DMG"

# --- 6. Notarize + staple
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "notarytool" --wait
  xcrun stapler staple "$DMG"
fi

# --- 7. Appcast (only the newest DMG needs an entry; pre-Sparkle versions
#         can't read it anyway)
rm -rf "$ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR"
cp "$DMG" "$ARCHIVE_DIR/"
if [ -n "$NOTES_HTML" ]; then
  cp "$NOTES_HTML" "$ARCHIVE_DIR/WindowPilot-${VERSION}.html"
fi
if [ -f "$ED_KEY_FILE" ]; then
  "$TOOLS/generate_appcast" --ed-key-file "$ED_KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --maximum-deltas 0 -o appcast.xml "$ARCHIVE_DIR"
else
  # Keychain lookup — works in interactive shells where the ACL dialog can appear
  "$TOOLS/generate_appcast" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --maximum-deltas 0 -o appcast.xml "$ARCHIVE_DIR"
fi

# --- 8. Publish. Order matters: the release (with the DMG asset) must exist
#         BEFORE the appcast that points at it goes live, or Sparkle clients
#         see a 404 enclosure.
if [ "${DRY_RUN:-0}" != "1" ]; then
  BRANCH="$(git branch --show-current)"
  if [ "$BRANCH" != "main" ]; then
    echo "Refusing to publish from branch '$BRANCH' — the feed lives on main" >&2
    exit 1
  fi
  # Push source FIRST — otherwise gh tags the remote's stale HEAD and the
  # release changelog points at pre-release code.
  git push origin HEAD:main
  gh release create "v${VERSION}" "$DMG" --title "WindowPilot v${VERSION}" \
    --generate-notes --target "$(git rev-parse HEAD)"
  git add appcast.xml
  git commit -m "Update appcast for v${VERSION}" -- appcast.xml
  git push origin HEAD:main
  echo "Released v${VERSION}."
else
  echo "DRY_RUN: skipped GitHub release and appcast commit. Artifacts: $DMG, appcast.xml"
fi
