#!/usr/bin/env bash
#
# Runs swift-format (the one bundled with Xcode) over every Swift source in the repo using
# the repository's .swift-format configuration.
#
# Usage: scripts/format.sh          reformat in place
#        scripts/format.sh --lint   check only (non-zero exit on violations; used by CI)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PATHS=(
    "$ROOT/Wayfork/App"
    "$ROOT/Wayfork/Daemon"
    "$ROOT/Wayfork/WayforkCore/Package.swift"
    "$ROOT/Wayfork/WayforkCore/Sources"
    "$ROOT/Wayfork/WayforkCore/Tests"
)

if [[ "${1:-}" == "--lint" ]]; then
    xcrun swift-format lint --strict --recursive --configuration "$ROOT/.swift-format" "${PATHS[@]}"
else
    xcrun swift-format format --in-place --recursive --configuration "$ROOT/.swift-format" "${PATHS[@]}"
fi
