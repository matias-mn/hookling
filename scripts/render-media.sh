#!/usr/bin/env bash
#
# Regenerate the README's demo media from a spritesheet.
#
#   scripts/render-media.sh <spritesheet> "<credit line>"
#
# Writes docs/media/demo.gif (for the README), docs/media/demo.mp4 (2x, for
# sharing) and docs/media/states.png. Needs ffmpeg (brew install ffmpeg).
#
# Only use artwork you have permission to publish: these files are committed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

[[ $# -eq 2 ]] || { echo "usage: scripts/render-media.sh <spritesheet> \"<credit line>\"" >&2; exit 2; }
SHEET="$1"
CREDIT="$2"
command -v ffmpeg >/dev/null || { echo "render-media: needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

OUT="$REPO_ROOT/docs/media"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

swift "$REPO_ROOT/scripts/render-media.swift" "$SHEET" "$WORK/frames" "$OUT/states.png" "$CREDIT"

# GIF: one palette for the whole clip, no dithering, which keeps pixel art crisp
# and the file small.
ffmpeg -loglevel error -y -framerate 25 -i "$WORK/frames/frame-%05d.png" \
    -vf "palettegen=max_colors=128:stats_mode=full" "$WORK/palette.png"
ffmpeg -loglevel error -y -framerate 25 -i "$WORK/frames/frame-%05d.png" -i "$WORK/palette.png" \
    -lavfi "paletteuse=dither=none" -loop 0 "$OUT/demo.gif"

# MP4 at 2x with nearest-neighbour scaling, for posting elsewhere.
ffmpeg -loglevel error -y -framerate 25 -i "$WORK/frames/frame-%05d.png" \
    -vf "scale=iw*2:ih*2:flags=neighbor,format=yuv420p" \
    -c:v libx264 -crf 18 -preset slow -movflags +faststart "$OUT/demo.mp4"

ls -lh "$OUT"
