#!/bin/sh
#
# Xcode "Bundle Binaries" build phase: copies the fetched sing-box/openvpn binaries into
# Wayfork.app/Contents/Resources/bin/ and signs them with the app's identity.
# Missing binaries only produce a warning so CI and fresh clones still build; run
# scripts/fetch-bins.sh to get them.

set -eu

SRC="${SRCROOT:?}/Resources/bin"
DST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"

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
