#!/usr/bin/env bash
#
# Build Hookling: the Swift package, the .app bundle, and the C hook client.
#
# The bundle is assembled by hand rather than with xcodebuild, because this
# project only needs the Command Line Tools. A real bundle (rather than the bare
# SwiftPM binary) is what makes LSUIElement, a stable preferences domain, and
# login-item registration work.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/Hookling.app"
BUNDLE_ID="dev.hookling"
VERSION="1.0.0"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Swift package
# ---------------------------------------------------------------------------
bold "Building the Swift package ($CONFIGURATION)"
swift build --package-path "$REPO_ROOT/app" -c "$CONFIGURATION"

BIN_DIR="$(swift build --package-path "$REPO_ROOT/app" -c "$CONFIGURATION" --show-bin-path)"

# ---------------------------------------------------------------------------
# 2. The hook client
# ---------------------------------------------------------------------------
# Written in C and compiled separately because it runs on every single tool call.
# Process startup dominates its cost, and a C binary starts in about a
# millisecond where a Swift one takes ten or more.
bold "Building the hook client"
mkdir -p "$BUILD_DIR/bin"
clang -O2 -Wall -Wextra -std=c11 \
    -o "$BUILD_DIR/bin/hookling-hook" \
    "$REPO_ROOT/adapters/claude-code/hooks/hookling-hook.c"

# The plugin invokes it via ${CLAUDE_PLUGIN_ROOT}, so it must also live inside the
# plugin directory.
mkdir -p "$REPO_ROOT/adapters/claude-code/plugin/bin"
cp "$BUILD_DIR/bin/hookling-hook" "$REPO_ROOT/adapters/claude-code/plugin/bin/hookling-hook"

# ---------------------------------------------------------------------------
# 3. The .app bundle
# ---------------------------------------------------------------------------
bold "Assembling Hookling.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_DIR/Hookling" "$APP_BUNDLE/Contents/MacOS/Hookling"

# The single copy of the animation data travels into the bundle. Tests read the
# same file from assets/, so the two cannot drift.
cp "$REPO_ROOT/assets/pet/animations.json" "$APP_BUNDLE/Contents/Resources/animations.json"

# Any artwork the user has already put in assets/ comes along for the ride. This
# is never committed to git - see docs/licensing.md.
shopt -s nullglob
for sheet in "$REPO_ROOT"/assets/pet/*.webp "$REPO_ROOT"/assets/pet/*.png; do
    cp "$sheet" "$APP_BUNDLE/Contents/Resources/"
done
shopt -u nullglob

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Hookling</string>
    <key>CFBundleDisplayName</key>     <string>Hookling</string>
    <key>CFBundleExecutable</key>      <string>Hookling</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>

    <!-- An accessory app: menu bar only, no Dock icon, never the active app. -->
    <key>LSUIElement</key>             <true/>

    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSSupportsSuddenTermination</key>    <false/>

    <key>NSHumanReadableCopyright</key>
    <string>Unofficial. Not affiliated with OpenAI or Anthropic. No pet artwork is included.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not for distribution - it just keeps macOS from re-evaluating
# the bundle on every launch, which otherwise resets things like the login item.
codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 || \
    echo "  (ad-hoc codesign unavailable; the app still runs)"

# ---------------------------------------------------------------------------
# 4. CLI
# ---------------------------------------------------------------------------
cp "$BIN_DIR/hooklingctl" "$BUILD_DIR/bin/hooklingctl"

bold "Done"
cat <<SUMMARY

  app:          $APP_BUNDLE
  hooklingctl:  $BUILD_DIR/bin/hooklingctl
  hook:         $BUILD_DIR/bin/hookling-hook

  Summon Hookling: ./scripts/run.sh
  Try animations:  ./build/bin/hooklingctl demo

SUMMARY
