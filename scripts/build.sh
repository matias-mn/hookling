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
# UNIVERSAL=1 builds for both Apple Silicon and Intel, as scripts/package.sh does
# for releases. The default is this Mac's architecture only, which is faster.
UNIVERSAL="${UNIVERSAL:-0}"
# RELEASE=1 builds a bundle that is safe to publish: artwork is never copied
# into it, whatever is sitting in assets/pet. scripts/package.sh sets this.
RELEASE="${RELEASE:-0}"
BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/Hookling.app"
BUNDLE_ID="dev.hookling"
# One version number, kept in the plugin manifest.
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$REPO_ROOT/adapters/claude-code/plugin/.claude-plugin/plugin.json")"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Swift package
# ---------------------------------------------------------------------------
# A universal SwiftPM build (--arch arm64 --arch x86_64) needs full Xcode, so
# each architecture is built on its own and the two are merged with lipo.
if [[ "$UNIVERSAL" == "1" ]]; then
    ARCHES=(arm64 x86_64)
else
    ARCHES=("$(uname -m)")
fi

ARCH_BIN_DIRS=()
for arch in "${ARCHES[@]}"; do
    triple="$arch-apple-macosx13.0"
    bold "Building the Swift package ($CONFIGURATION, $arch)"
    swift build --package-path "$REPO_ROOT/app" -c "$CONFIGURATION" --triple "$triple"
    ARCH_BIN_DIRS+=("$(swift build --package-path "$REPO_ROOT/app" -c "$CONFIGURATION" --triple "$triple" --show-bin-path)")
done

BIN_DIR="$BUILD_DIR/swift-bin"
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"
for product in Hookling hooklingctl; do
    inputs=()
    for dir in "${ARCH_BIN_DIRS[@]}"; do inputs+=("$dir/$product"); done
    lipo -create "${inputs[@]}" -output "$BIN_DIR/$product"
done

# ---------------------------------------------------------------------------
# 2. The hook client
# ---------------------------------------------------------------------------
# Written in C and compiled separately because it runs on every single tool call.
# Process startup dominates its cost, and a C binary starts in about a
# millisecond where a Swift one takes ten or more.
bold "Building the hook client"
mkdir -p "$BUILD_DIR/bin"
CLANG_ARCH_FLAGS=()
for arch in "${ARCHES[@]}"; do CLANG_ARCH_FLAGS+=(-arch "$arch"); done
clang -O2 -Wall -Wextra -std=c11 "${CLANG_ARCH_FLAGS[@]}" -mmacosx-version-min=13.0 \
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

# The hook and the CLI travel inside the bundle, so a downloaded app is complete
# on its own. On launch the app copies the hook to
# ~/Library/Application Support/Hookling/bin, where the plugin looks for it when
# it was installed from GitHub and so has no compiled hook of its own.
cp "$BUILD_DIR/bin/hookling-hook" "$APP_BUNDLE/Contents/MacOS/hookling-hook"
cp "$BIN_DIR/hooklingctl" "$APP_BUNDLE/Contents/MacOS/hooklingctl"

# The single copy of the animation data travels into the bundle. Tests read the
# same file from assets/, so the two cannot drift.
cp "$REPO_ROOT/assets/pet/animations.json" "$APP_BUNDLE/Contents/Resources/animations.json"

# For a local build, any artwork the user has already put in assets/ comes along
# for the ride. It is never committed to git, and never copied into a release
# bundle, because it is not ours to distribute - see docs/licensing.md.
if [[ "$RELEASE" != "1" ]]; then
    shopt -s nullglob
    for sheet in "$REPO_ROOT"/assets/pet/*.webp "$REPO_ROOT"/assets/pet/*.png; do
        cp "$sheet" "$APP_BUNDLE/Contents/Resources/"
    done
    shopt -u nullglob
fi

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

# Ad-hoc signature. It is not a Developer ID, so macOS still asks before opening a
# downloaded copy (see the README), but it keeps macOS from re-evaluating the
# bundle on every launch, which otherwise resets things like the login item.
# The helpers are signed first, because the bundle's signature covers them.
if codesign --force --sign - --timestamp=none "$APP_BUNDLE/Contents/MacOS/hookling-hook" \
       "$APP_BUNDLE/Contents/MacOS/hooklingctl" >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1
else
    echo "  (ad-hoc codesign unavailable; the app still runs)"
fi

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
