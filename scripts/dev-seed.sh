#!/usr/bin/env bash
#
# Points the app at the git-ignored local/ folder so an empty store is seeded with the
# real configs there on launch (see local/README.md). Optional --reset wipes the current
# store so the next launch seeds again.
#
# Usage: scripts/dev-seed.sh [--reset] [--off]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$HOME/Library/Application Support/Wayfork/store.json"

case "${1:-}" in
    --off)
        defaults delete com.wayfork.app WayforkSeedDirectory 2>/dev/null || true
        echo "seeding disabled"
        exit 0
        ;;
    --reset)
        osascript -e 'tell application "Wayfork" to quit' 2>/dev/null || true
        sleep 1
        rm -f "$STORE"
        echo "store removed: $STORE"
        ;;
    "") ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
esac

defaults write com.wayfork.app WayforkSeedDirectory -string "$ROOT/local"
echo "WayforkSeedDirectory = $ROOT/local"
