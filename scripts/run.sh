#!/usr/bin/env bash
#
# Summon Hookling. This is the one command.
#
# Builds if needed, replaces any pet already running, and leaves the new one
# running in the background with its log on disk.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

APP_BUNDLE="$REPO_ROOT/build/Hookling.app"
BINARY="$APP_BUNDLE/Contents/MacOS/Hookling"
HOOKLINGCTL="$REPO_ROOT/build/bin/hooklingctl"
LOG="$REPO_ROOT/build/hookling.log"

if [[ ! -x "$BINARY" ]]; then
    echo "Hookling is not built yet - building now."
    "$REPO_ROOT/scripts/build.sh"
fi

# Ask an existing pet to quit, so this script is idempotent and never leaves two
# instances fighting over the socket.
if [[ -x "$HOOKLINGCTL" ]]; then
    "$HOOKLINGCTL" quit >/dev/null 2>&1 || true
fi
# Give the old process a moment to release the socket.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Hookling >/dev/null 2>&1 || break
    sleep 0.1
done
pkill -x Hookling >/dev/null 2>&1 || true

mkdir -p "$(dirname "$LOG")"
nohup "$BINARY" >"$LOG" 2>&1 &
PET_PID=$!

# Wait for the socket to appear, so a follow-up hooklingctl command cannot race it.
SOCKET="${HOOKLING_SOCKET:-$HOME/Library/Application Support/Hookling/hookling.sock}"
for _ in $(seq 1 40); do
    [[ -S "$SOCKET" ]] && break
    sleep 0.05
done

echo "Hookling is running (pid $PET_PID)."
echo
if [[ -S "$SOCKET" ]]; then
    echo "  socket:  $SOCKET"
else
    echo "  socket:  NOT LISTENING - see the log"
fi
echo "  log:     $LOG"
echo "  menu:    look for the paw print in the menu bar"
echo
sed -n '1,20p' "$LOG" 2>/dev/null || true
echo
echo "Next:"
echo "  ./build/bin/hooklingctl status     # what is he doing?"
echo "  ./build/bin/hooklingctl demo       # walk every animation"
echo "  ./build/bin/hooklingctl quit       # send him home"
