#!/usr/bin/env bash
#
# Fetches the pinned block list (scripts/versions.env, BLOCKLIST_*), converts it to
# sing-box's source rule-set format (one domain_suffix per entry) and compiles it with the
# bundled sing-box into Wayfork/Resources/rulesets/block-ads.srs, next to a block-ads.json
# sidecar (entry count, source, version) the app shows in Settings › General (F18,
# docs/design/03-routing.md, "Block list"). Both files are git-ignored and copied into the
# bundle by scripts/embed-bins.sh.
#
# Usage: scripts/fetch-blocklist.sh
#
# Requirements: scripts/fetch-bins.sh has run (the compiler is the bundled sing-box), curl.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

SING_BOX="$ROOT/Wayfork/Resources/bin/sing-box"
OUT_DIR="$ROOT/Wayfork/Resources/rulesets"
BUILD_DIR="${WAYFORK_BUILD_DIR:-$ROOT/build/blocklist}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$SING_BOX" ]] || die "$SING_BOX not found; run scripts/fetch-bins.sh first"
mkdir -p "$BUILD_DIR" "$OUT_DIR"

RAW="$BUILD_DIR/blocklist-$BLOCKLIST_COMMIT.txt"
if [[ ! -f "$RAW" ]]; then
    log "Downloading $BLOCKLIST_NAME ($BLOCKLIST_COMMIT)"
    curl -fsSL --retry 3 -o "$RAW.part" "$BLOCKLIST_URL"
    mv "$RAW.part" "$RAW"
fi
ACTUAL="$(shasum -a 256 "$RAW" | cut -d' ' -f1)"
[[ "$ACTUAL" == "$BLOCKLIST_SHA256" ]] \
    || die "checksum mismatch for the block list: expected $BLOCKLIST_SHA256, got $ACTUAL"

log "Converting to a sing-box rule-set"
SOURCE="$BUILD_DIR/block-ads.source.json"
VERSION="$(sed -n 's/^# Version: *//p' "$RAW" | head -1)"
# Entries: lowercase hostnames only; comments and blank lines dropped; anything else is a
# format change worth a look rather than a silent skip.
grep -v '^#' "$RAW" | grep -v '^[[:space:]]*$' | tr -d '\r' > "$BUILD_DIR/entries.txt"
if grep -qv '^[a-z0-9.-]*$' "$BUILD_DIR/entries.txt"; then
    die "unexpected entry in the block list: $(grep -vm1 '^[a-z0-9.-]*$' "$BUILD_DIR/entries.txt")"
fi
COUNT="$(wc -l < "$BUILD_DIR/entries.txt" | tr -d ' ')"
{
    printf '{"version":3,"rules":[{"domain_suffix":['
    awk 'NR > 1 { printf "," } { printf "\"%s\"", $0 }' "$BUILD_DIR/entries.txt"
    printf ']}]}\n'
} > "$SOURCE"

log "Compiling $COUNT entries"
"$SING_BOX" rule-set compile --output "$OUT_DIR/block-ads.srs" "$SOURCE"
cat > "$OUT_DIR/block-ads.json" <<JSON
{
  "name": "$BLOCKLIST_NAME",
  "homepage": "$BLOCKLIST_HOMEPAGE",
  "license": "$BLOCKLIST_LICENSE",
  "commit": "$BLOCKLIST_COMMIT",
  "version": "$VERSION",
  "entries": $COUNT
}
JSON
log "Wrote $OUT_DIR/block-ads.srs ($(du -h "$OUT_DIR/block-ads.srs" | cut -f1)) and block-ads.json"
