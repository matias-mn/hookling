#!/usr/bin/env bash
#
# Build the downloadable release: dist/Hookling.zip and its SHA-256.
#
# The asset names carry no version on purpose. GitHub serves the newest release
# at a fixed URL (/releases/latest/download/Hookling.zip), which is what
# scripts/install.sh downloads, so the installer never needs updating.
#
# Publishing is a separate, deliberate step:
#
#   gh release create v<version> dist/Hookling.zip dist/Hookling.zip.sha256
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"
APP_BUNDLE="$REPO_ROOT/build/Hookling.app"
DIST_DIR="$REPO_ROOT/dist"
ZIP="$DIST_DIR/Hookling.zip"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[1;31mpackage: %s\033[0m\n' "$1" >&2; exit 1; }

RELEASE=1 UNIVERSAL=1 CONFIGURATION=release "$REPO_ROOT/scripts/build.sh"

bold "Checking the bundle before it goes anywhere"

# The one check that must never be skipped: no artwork of any kind in a
# published bundle. See docs/licensing.md.
artwork="$(find "$APP_BUNDLE" -type f \( -iname '*.webp' -o -iname '*.png' -o -iname '*.gif' \) )"
[[ -z "$artwork" ]] || fail "artwork found in the bundle, refusing to package:
$artwork"

for binary in Hookling hooklingctl hookling-hook; do
    path="$APP_BUNDLE/Contents/MacOS/$binary"
    [[ -x "$path" ]] || fail "missing $binary"
    arches="$(lipo -archs "$path")"
    [[ "$arches" == *arm64* && "$arches" == *x86_64* ]] || fail "$binary is not universal ($arches)"
    echo "  $binary: $arches"
done
codesign --verify --strict "$APP_BUNDLE" || fail "bundle signature does not verify"
echo "  signature: ad-hoc, verifies"

bold "Zipping"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
# ditto, not zip: it keeps the bundle's permissions and signature intact. Extended
# attributes are left out, so the archive has no ._ clutter in other unzip tools.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_BUNDLE" "$ZIP"
(cd "$DIST_DIR" && shasum -a 256 Hookling.zip > Hookling.zip.sha256)

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
bold "Done"
cat <<SUMMARY

  version:  $VERSION
  zip:      $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))
  sha256:   $(cut -d' ' -f1 "$ZIP.sha256")

  Publish with:
    gh release create v$VERSION dist/Hookling.zip dist/Hookling.zip.sha256

SUMMARY
