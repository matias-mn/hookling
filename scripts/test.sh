#!/usr/bin/env bash
#
# Run the HooklingCore test suite.
#
# Tests use swift-testing (`import Testing`) rather than XCTest, because XCTest
# ships only inside Xcode while swift-testing ships with the Command Line Tools —
# and this project is built with CLT alone. The catch is that SwiftPM does not
# add the CLT framework search paths automatically, so we pass them here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

DEVELOPER_DIR_PATH="$(xcode-select -p)"
EXTRA_FLAGS=()

if [[ -d "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks" ]]; then
    # Command Line Tools layout.
    FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
    LIBRARIES="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
elif [[ -d "$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks" ]]; then
    # Full Xcode layout. Usually unnecessary, but harmless and keeps this script
    # working on machines that have Xcode instead.
    FRAMEWORKS="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    LIBRARIES="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/usr/lib"
else
    FRAMEWORKS=""
    LIBRARIES=""
fi

if [[ -n "$FRAMEWORKS" ]]; then
    EXTRA_FLAGS+=(-Xswiftc -F -Xswiftc "$FRAMEWORKS")
    EXTRA_FLAGS+=(-Xlinker -F -Xlinker "$FRAMEWORKS")
    EXTRA_FLAGS+=(-Xlinker -rpath -Xlinker "$FRAMEWORKS")
fi
if [[ -n "$LIBRARIES" ]]; then
    EXTRA_FLAGS+=(-Xlinker -rpath -Xlinker "$LIBRARIES")
fi

exec swift test --package-path "$REPO_ROOT/app" "${EXTRA_FLAGS[@]}" "$@"
