#!/usr/bin/env bash
#
# Install the latest prebuilt Hookling.
#
#   curl -fsSL https://raw.githubusercontent.com/matias-mn/hookling/main/scripts/install.sh | bash
#
# What it does, and nothing else:
#   1. downloads Hookling.zip and its checksum from the latest GitHub release
#   2. checks the checksum
#   3. puts Hookling.app in /Applications, or ~/Applications if that is not
#      writable (no sudo, ever)
#   4. starts it
#
# The app is ad-hoc signed, not notarized. A file fetched by curl is not
# quarantined, so macOS does not block it, which is the point of this script.
# Read it before you run it; it is short on purpose.
set -euo pipefail

REPO="matias-mn/hookling"
# Both overridable, which is how the script is tested without a real release.
DOWNLOAD_BASE="${HOOKLING_DOWNLOAD_BASE:-https://github.com/$REPO/releases/latest/download}"
INSTALL_DIR="${HOOKLING_INSTALL_DIR:-}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[1;31mhookling install: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Hookling is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "Hookling needs macOS 13 or later (this Mac has $(sw_vers -productVersion))."

if [[ -z "$INSTALL_DIR" ]]; then
    if [[ -w /Applications ]]; then INSTALL_DIR="/Applications"; else INSTALL_DIR="$HOME/Applications"; fi
fi
mkdir -p "$INSTALL_DIR"
APP="$INSTALL_DIR/Hookling.app"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bold "Downloading Hookling"
curl -fL --progress-bar -o "$WORK/Hookling.zip" "$DOWNLOAD_BASE/Hookling.zip" \
    || fail "download failed from $DOWNLOAD_BASE/Hookling.zip"
curl -fsSL -o "$WORK/Hookling.zip.sha256" "$DOWNLOAD_BASE/Hookling.zip.sha256" \
    || fail "could not download the checksum"

bold "Checking the download"
(cd "$WORK" && shasum -a 256 -c Hookling.zip.sha256 >/dev/null) \
    || fail "checksum mismatch - the download is corrupt or has been tampered with. Nothing was installed."
echo "  checksum OK"

ditto -x -k "$WORK/Hookling.zip" "$WORK/unzipped"
[[ -d "$WORK/unzipped/Hookling.app" ]] || fail "the download does not contain Hookling.app"

bold "Installing to $APP"
# Quit a running copy first, so it lets go of its socket and files.
if pgrep -x Hookling >/dev/null 2>&1; then
    osascript -e 'tell application id "dev.hookling" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Hookling >/dev/null 2>&1 || break; sleep 0.2; done
    pkill -x Hookling >/dev/null 2>&1 || true
fi
rm -rf "$APP"
ditto "$WORK/unzipped/Hookling.app" "$APP"
# Belt and braces: curl does not set the quarantine flag, but a copy made some
# other way might have it.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

bold "Starting Hookling"
open "$APP"

cat <<NEXT

Hookling is installed and running. Look for the paw print in the menu bar.

Next, connect Claude Code. Run these two commands inside Claude Code:

    /plugin marketplace add $REPO
    /plugin install hookling@hookling

Then quit and reopen Claude Code.

No pet artwork is included. If you use Codex, choose a pet there (codex, then
/pets) and Hookling finds it automatically. Otherwise see:
https://github.com/$REPO#4-get-some-pet-artwork

NEXT
