#!/usr/bin/env bash
#
# Find pet artwork for Hookling, without this project ever redistributing it.
#
# The artwork is OpenAI's. It is not in this repository, it is gitignored so it
# can never be committed by accident, and this script never invents a substitute.
# See docs/licensing.md for the full analysis; the short version is:
#
#   default       read the copy Codex already put on this machine, and link it.
#                 No download, no bytes shipped, no requests to OpenAI.
#   --from-cdn    fetch from the same public URL Codex uses. Deliberate, opt-in,
#                 and never implicit, because it is unsanctioned and revocable.
#
# Any 8x9 grid of 192x208 frames works - any of the Codex pets, or your own art.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

ANIMATIONS="$REPO_ROOT/assets/pet/animations.json"
DEST_DIR="$REPO_ROOT/assets/pet"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_CACHE="$CODEX_HOME/cache/tui-pets/v1/assets"

# Where `npx codex-pets add <id>` puts community pets. We read from and write to
# exactly this directory, so a pet fetched by this script and one fetched by the
# official CLI are interchangeable — and neither ever lands inside this repo.
COMMUNITY_DIR="$CODEX_HOME/pets"
COMMUNITY_SITE="https://codex-pets.net"

# The same constants as codex-rs/tui/src/pets/asset_pack.rs.
CDN_BASE="https://persistent.oaistatic.com/codex/pets/v1"
MAX_DOWNLOAD_BYTES=$((4 * 1024 * 1024))

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; }

# The catalog is the single source of truth for the filename and the geometry, so
# this script cannot drift from what the app will actually accept.
json_value() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' \
        "$ANIMATIONS" | head -1
}

# Pull one string field out of an arbitrary JSON file. Enough for the handful of
# fields we read off the community API, and it keeps this script dependency-free.
api_value() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$2" | head -1
}

if [[ ! -f "$ANIMATIONS" ]]; then
    fail "Cannot find $ANIMATIONS - are you running this from the repo?"
    exit 1
fi

SHEET_FILE="$(json_value file)"
FRAME_W="$(json_value frameWidth)"
FRAME_H="$(json_value frameHeight)"
COLUMNS="$(json_value columns)"
ROWS="$(json_value rows)"
EXPECT_W=$((FRAME_W * COLUMNS))
EXPECT_H=$((FRAME_H * ROWS))

FROM_CDN=0
PET=""
LIST_PETS=0
COMMUNITY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-cdn) FROM_CDN=1; shift ;;
        --list-pets) LIST_PETS=1; shift ;;
        --community)
            [[ $# -ge 2 ]] || { fail "--community needs a pet id, e.g. --community jiji"; exit 2; }
            COMMUNITY="$2"; shift 2
            ;;
        --pet)
            [[ $# -ge 2 ]] || { fail "--pet needs a name (try --list-pets)"; exit 2; }
            PET="$2"; shift 2
            ;;
        -h|--help)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            cat <<USAGE

USAGE: scripts/fetch-pet.sh [--pet <name> | --community <id> | --list-pets | --from-cdn]

  --pet <name>   render as one of the other Codex pets instead. Any of them
                 fits: they all ship the same grid. Also finds community pets
                 installed by \`npx codex-pets add\`. "--pet none" goes back to
                 whatever would be discovered normally.
  --community <id>
                 fetch a community pet from $COMMUNITY_SITE by id (the last
                 part of its page URL) and switch to it. Installs into
                 ~/.codex/pets/<id>/, the same place \`npx codex-pets add\`
                 uses, so the two are interchangeable.
  --list-pets    show which pets are on this machine, from both sources
  --from-cdn     download from OpenAI's CDN. Read the caveat it prints.

  Wants: $SHEET_FILE  (${EXPECT_W}x${EXPECT_H}, an
         ${COLUMNS}x${ROWS} grid of ${FRAME_W}x${FRAME_H} frames)
USAGE
            exit 0
            ;;
        *) fail "Unknown option: $1"; exit 2 ;;
    esac
done

# Best-effort dimension check. `sips` cannot always read webp, so a failure here
# is a warning: the app validates properly on load and refuses a mismatch.
check_dimensions() {
    local path="$1" width height
    width="$(sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
    height="$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ {print $2}')"

    if [[ -z "$width" || -z "$height" ]]; then
        warn "  (could not read the dimensions here; the app will verify them on load)"
        return 0
    fi
    if [[ "$width" != "$EXPECT_W" || "$height" != "$EXPECT_H" ]]; then
        fail "  $path is ${width}x${height}, but a sheet must be ${EXPECT_W}x${EXPECT_H}."
        return 1
    fi
    echo "  verified ${width}x${height}"
}

# The app reads this preference before it looks in the Codex cache, so it is what
# makes a choice of pet stick. Exactly the key the menu's "Choose pet
# artwork..." writes - this is a shortcut to it, not a second mechanism.
PREFERENCE_DOMAIN="dev.hookling"
PREFERENCE_KEY="spritesheetPath"

# ---------------------------------------------------------------------------
# Community pets from codex-pets.net
# ---------------------------------------------------------------------------
# That site hosts two sprite formats. Version 1 is the 1536x1872 grid this app
# (and Codex itself) speaks; version 2 is a taller 1536x2288 sheet with extra
# rows. Checking the API's own validation report first means a v2 pet is refused
# here with a sentence that explains why, rather than by the app failing to
# decode a sheet the user has already downloaded.
if [[ -n "$COMMUNITY" ]]; then
    META="$(mktemp)"
    trap 'rm -f "$META"' EXIT

    bold "Looking up '$COMMUNITY' on $COMMUNITY_SITE"
    # No --show-error: a 404 here is the ordinary "typo in the id" case, and the
    # message below says more than curl's would.
    if ! curl --fail --location --silent --max-time 30 \
              --output "$META" "$COMMUNITY_SITE/api/pets/$COMMUNITY" 2>/dev/null; then
        fail "No pet with id '$COMMUNITY'."
        echo "The id is the last part of the page URL, e.g."
        echo "  $COMMUNITY_SITE/#/pets/jiji  ->  --community jiji"
        exit 1
    fi

    NAME="$(api_value displayName "$META")"
    OWNER="$(api_value ownerHandle "$META")"
    ATLAS="$(api_value atlasSize "$META")"
    CELL="$(api_value cellSize "$META")"
    SHEET_URL="$(api_value spritesheetUrl "$META")"

    echo "  ${NAME:-$COMMUNITY}${OWNER:+  by @$OWNER}"
    echo "  sheet: ${ATLAS:-unknown}, cells ${CELL:-unknown}"

    if [[ -z "$SHEET_URL" ]]; then
        fail "The API gave no spritesheet URL for '$COMMUNITY'."
        exit 1
    fi
    if [[ "$ATLAS" != "${EXPECT_W}x${EXPECT_H}" ]]; then
        fail "'$COMMUNITY' is a ${ATLAS:-unknown} sheet; this app needs ${EXPECT_W}x${EXPECT_H}."
        echo
        echo "That is a version 2 pet: same artwork style, but extra animation rows"
        echo "this app has no states for. Look for a v1 pet instead - the site marks"
        echo "the version on each pet's page."
        exit 1
    fi

    DEST="$COMMUNITY_DIR/$COMMUNITY"
    mkdir -p "$DEST"
    TARGET="$DEST/spritesheet.webp"

    bold "Fetching $COMMUNITY"
    # Same 4 MiB ceiling and atomic install as the --from-cdn path: never leave a
    # half-written sheet somewhere the app might try to decode it.
    if ! curl --fail --location --silent --show-error \
              --max-filesize "$MAX_DOWNLOAD_BYTES" \
              --max-time 120 \
              --output "$TARGET.partial" \
              "$SHEET_URL"; then
        fail "Download failed from $SHEET_URL"
        rm -f "$TARGET.partial"
        exit 1
    fi
    mv -f "$TARGET.partial" "$TARGET"
    echo "  wrote: $TARGET  ($(wc -c <"$TARGET" | tr -d ' ') bytes)"
    check_dimensions "$TARGET" || exit 1

    defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -string "$TARGET"
    echo
    bold "Hookling will render as ${NAME:-$COMMUNITY}"
    echo "  This artwork belongs to its author${OWNER:+ (@$OWNER)}, not to this project."
    echo "  It lives outside the repository and is never committed."
    echo
    echo "Restart to apply:  ./scripts/run.sh"
    echo "Undo with:         scripts/fetch-pet.sh --pet none"
    exit 0
fi

if [[ "$LIST_PETS" -eq 1 ]]; then
    if [[ ! -d "$CODEX_CACHE" && ! -d "$COMMUNITY_DIR" ]]; then
        fail "No pets on this machine yet."
        echo "Run codex, type /pets, and pick one - it downloads the whole set."
        echo "Or fetch a community pet:  scripts/fetch-pet.sh --community <id>"
        exit 1
    fi
    current="$(defaults read "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" 2>/dev/null || true)"
    shopt -s nullglob

    if [[ -d "$CODEX_CACHE" ]]; then
        bold "Pets in your Codex cache"
        for sheet in "$CODEX_CACHE"/*-spritesheet-v4.webp; do
            name="$(basename "$sheet")"; name="${name%%-spritesheet-v4.webp}"
            marker="  "
            [[ "$sheet" == "$current" ]] && marker=" *"
            printf '%s %-12s %s\n' "$marker" "$name" "$sheet"
        done
    fi

    if [[ -d "$COMMUNITY_DIR" ]]; then
        found=0
        for sheet in "$COMMUNITY_DIR"/*/spritesheet.webp; do
            [[ "$found" -eq 0 ]] && { echo; bold "Community pets"; found=1; }
            name="$(basename "$(dirname "$sheet")")"
            marker="  "
            [[ "$sheet" == "$current" ]] && marker=" *"
            printf '%s %-12s %s\n' "$marker" "$name" "$sheet"
        done
    fi

    shopt -u nullglob
    echo
    echo "  * = currently selected.  Switch with: scripts/fetch-pet.sh --pet <name>"
    echo "  More at $COMMUNITY_SITE  ->  scripts/fetch-pet.sh --community <id>"
    exit 0
fi

if [[ -n "$PET" ]]; then
    if [[ "$PET" == "none" || "$PET" == "default" ]]; then
        defaults delete "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" 2>/dev/null || true
        bold "Cleared the pet override"
        echo "  The default Seedy sheet will be discovered normally again."
        echo
        echo "Restart to apply:  ./scripts/run.sh"
        exit 0
    fi

    # Codex's own pets first, then anything `npx codex-pets add` (or this
    # script's --community) has installed. One flag, both sources.
    PET_SHEET="$CODEX_CACHE/${PET}-spritesheet-v4.webp"
    if [[ ! -f "$PET_SHEET" ]]; then
        PET_SHEET="$COMMUNITY_DIR/$PET/spritesheet.webp"
    fi
    if [[ ! -f "$PET_SHEET" ]]; then
        fail "No sheet for '$PET' on this machine."
        echo "Looked in:"
        echo "  $CODEX_CACHE/${PET}-spritesheet-v4.webp"
        echo "  $COMMUNITY_DIR/$PET/spritesheet.webp"
        echo
        echo "Try:  scripts/fetch-pet.sh --list-pets"
        echo "  or: scripts/fetch-pet.sh --community $PET"
        exit 1
    fi

    check_dimensions "$PET_SHEET" || exit 1
    defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -string "$PET_SHEET"
    bold "Hookling will render as $PET"
    echo "  sheet: $PET_SHEET"
    echo "  (read in place from your Codex cache - nothing was copied)"
    echo
    echo "Restart to apply:  ./scripts/run.sh"
    echo "Undo with:         scripts/fetch-pet.sh --pet none"
    exit 0
fi

link_it() {
    local source="$1"
    mkdir -p "$DEST_DIR"
    # A symlink, not a copy: the bytes stay where their owner put them, and this
    # project keeps holding none of them.
    ln -sfn "$source" "$DEST_DIR/$SHEET_FILE"
    bold "Linked Seedy's artwork"
    echo "  from:  $source"
    echo "  to:    $DEST_DIR/$SHEET_FILE"
    check_dimensions "$source" || return 1
    echo
    echo "Next:  ./scripts/run.sh"
    echo "       ./build/bin/hooklingctl status     # should report the artwork"
}

# ---------------------------------------------------------------------------
# (b) Explicitly requested: fetch from the CDN
# ---------------------------------------------------------------------------
if [[ "$FROM_CDN" -eq 1 ]]; then
    cat <<'CAVEAT'
--from-cdn was requested. Before this runs, the caveat from docs/licensing.md:

  This endpoint is public and unauthenticated, and this only copies the file to
  your own machine - exactly what Codex itself does. But it is undocumented and
  unsanctioned, it uses OpenAI's bandwidth for a non-Codex product, and it can be
  changed or locked down at any time. No licence is granted anywhere for this
  artwork, and absence of a prohibition is not permission.

  The safe path is to let Codex download it: run `codex`, then `/pets`, and pick
  Seedy. This script with no arguments will then find it.

CAVEAT

    mkdir -p "$DEST_DIR"
    TARGET="$DEST_DIR/$SHEET_FILE"
    bold "Fetching $SHEET_FILE"
    echo "  from: $CDN_BASE/$SHEET_FILE"

    # --max-filesize mirrors the 4 MiB ceiling asset_pack.rs applies.
    if ! curl --fail --location --silent --show-error \
              --max-filesize "$MAX_DOWNLOAD_BYTES" \
              --max-time 60 \
              --output "$TARGET.partial" \
              "$CDN_BASE/$SHEET_FILE"; then
        fail "Download failed. The URL is internal plumbing and may have moved."
        rm -f "$TARGET.partial"
        exit 1
    fi

    # Atomic install, like asset_pack.rs: never leave a half-written sheet where
    # the app might try to decode it.
    mv -f "$TARGET.partial" "$TARGET"
    echo "  wrote: $TARGET  ($(wc -c <"$TARGET" | tr -d ' ') bytes)"
    check_dimensions "$TARGET"
    echo
    echo "This file is gitignored and will never be committed."
    echo "Next:  ./scripts/run.sh"
    exit 0
fi

# ---------------------------------------------------------------------------
# (c) Default: whatever is already on this machine
# ---------------------------------------------------------------------------

# Already sorted out?
if [[ -e "$DEST_DIR/$SHEET_FILE" ]]; then
    bold "Seedy's artwork is already in place"
    echo "  $DEST_DIR/$SHEET_FILE"
    if [[ -L "$DEST_DIR/$SHEET_FILE" ]]; then
        echo "  -> $(readlink "$DEST_DIR/$SHEET_FILE")"
    fi
    check_dimensions "$DEST_DIR/$SHEET_FILE" || exit 1
    exit 0
fi

if [[ -f "$CODEX_CACHE/$SHEET_FILE" ]]; then
    link_it "$CODEX_CACHE/$SHEET_FILE"
    exit 0
fi

# Nothing found. Say precisely what was looked for and what to do about it -
# never guess, and never download without being asked.
fail "Seedy's artwork is not on this machine yet."
echo
echo "Looked in:"
echo "  $DEST_DIR/$SHEET_FILE"
echo "  $CODEX_CACHE/$SHEET_FILE"
if [[ -d "$CODEX_HOME" ]]; then
    echo "      ($CODEX_HOME exists, but the pet pack has not been downloaded)"
else
    echo "      ($CODEX_HOME does not exist - Codex is not installed here)"
fi
echo
bold "Your options"
cat <<OPTIONS
  1. Let Codex fetch it (safest, and what docs/licensing.md recommends):
         npm install -g @openai/codex     # if it is not installed
         codex                            # then type /pets and choose Seedy
         ./scripts/fetch-pet.sh         # run this again

  2. Use artwork you already have - any ${COLUMNS}x${ROWS} grid of
     ${FRAME_W}x${FRAME_H} frames (${EXPECT_W}x${EXPECT_H} total):
         HOOKLING_SPRITESHEET=/path/to/sheet.png ./scripts/run.sh
     or pick it from the menu bar: "Choose pet artwork..."

  3. Fetch from the same public CDN Codex uses. Read the caveat first:
         ./scripts/fetch-pet.sh --from-cdn

  4. See it working with no artwork at all - a numbered diagnostic sheet that
     makes the sprite mapping obvious:
         ./build/bin/hooklingctl testsheet /tmp/testsheet.png
         HOOKLING_SPRITESHEET=/tmp/testsheet.png ./scripts/run.sh
OPTIONS
exit 1
