#!/bin/sh
#
# Xcode "Bundle Binaries" build phase: copies the fetched sing-box/openvpn binaries into
# Wayfork.app/Contents/Resources/bin/ and signs them with the app's identity, and the
# compiled block list (F18) into Contents/Resources/rulesets/.
# Missing binaries only produce a warning so CI and fresh clones still build; run
# scripts/fetch-bins.sh to get them, scripts/fetch-blocklist.sh for the list.

set -eu

SRC="${SRCROOT:?}/Resources/bin"
DST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
RULESETS_SRC="${SRCROOT:?}/Resources/rulesets"
RULESETS_DST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/rulesets"

if [ -f "$RULESETS_SRC/block-ads.srs" ]; then
    mkdir -p "$RULESETS_DST"
    cp -f "$RULESETS_SRC/block-ads.srs" "$RULESETS_SRC/block-ads.json" "$RULESETS_DST/"
else
    echo "warning: block list not found in $RULESETS_SRC; run scripts/fetch-blocklist.sh (the Block ads switch will be disabled)"
fi

if [ ! -x "$SRC/sing-box" ] || [ ! -x "$SRC/openvpn" ]; then
    echo "warning: bundled binaries not found in $SRC; run scripts/fetch-bins.sh (the app will not be able to start tunnels)"
    exit 0
fi

mkdir -p "$DST"
for bin in sing-box openvpn; do
    cp -f "$SRC/$bin" "$DST/$bin"
    chmod 755 "$DST/$bin"
done

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    for bin in sing-box openvpn; do
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --options runtime --timestamp=none \
            --identifier "com.wayfork.bin.$bin" \
            "$DST/$bin"
    done
fi
