#!/usr/bin/env bash
#
# Builds a distributable Wayfork: Xcode archive, Developer ID signing with hardened runtime
# and secure timestamps (app, daemon, bundled sing-box/openvpn), notarization through
# notarytool, stapling, and a signed + notarized DMG with a SHA-256 next to it.
#
# Usage: scripts/release.sh [--identity "<Developer ID Application: …>"]
#                           [--keychain-profile <name>] [--skip-notarize]
#                           [--skip-archive] [--version X.Y.Z]
#
#   WAYFORK_RELEASE_IDENTITY   default for --identity; otherwise the first
#                              "Developer ID Application" identity in the keychain.
#   WAYFORK_NOTARY_PROFILE     default for --keychain-profile: a notarytool credentials
#                              profile stored once with
#                                xcrun notarytool store-credentials <name> \
#                                    --apple-id <id> --team-id <team> --password <app-specific>
#   --skip-notarize            sign and package only, no notarization. Without a Developer
#                              ID this is the release mode: the first "Apple Development"
#                              identity is used when no --identity is given. The signature
#                              is valid everywhere (the daemon registers, the Team ID
#                              requirement holds), but Gatekeeper refuses to open the
#                              downloaded app until the user clears the quarantine flag
#                              (README, "Install").
#   --skip-archive             reuse build/release/Wayfork.xcarchive from a previous run.
#   --version X.Y.Z            must equal MARKETING_VERSION in the project — a guard
#                              against tagging a build of the wrong version.
#
# Output (build/release/):
#   Wayfork-<version>.dmg (+ .sha256)   what goes on the release page
#   Wayfork.app                         the signed (and stapled) bundle
#   Wayfork.xcarchive                   archive with dSYMs, keep it for crash symbolication
#
# Requires Xcode 26, scripts/fetch-bins.sh already run (universal binaries) and network
# access for the timestamp server and the notary service.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Wayfork/Wayfork.xcodeproj"
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/DerivedData"
ARCHIVE="$OUT/Wayfork.xcarchive"
APP="$OUT/Wayfork.app"
DAEMON_REL="Contents/MacOS/WayforkDaemon"
BIN_REL="Contents/Resources/bin"

IDENTITY="${WAYFORK_RELEASE_IDENTITY:-}"
PROFILE="${WAYFORK_NOTARY_PROFILE:-}"
SKIP_NOTARIZE=0
SKIP_ARCHIVE=0
WANT_VERSION=""

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        --keychain-profile) PROFILE="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --skip-archive) SKIP_ARCHIVE=1; shift ;;
        --version) WANT_VERSION="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------------------------
# Preflight

command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"
for bin in sing-box openvpn; do
    [[ -x "$ROOT/Wayfork/Resources/bin/$bin" ]] \
        || die "bundled binary missing: Wayfork/Resources/bin/$bin (run scripts/fetch-bins.sh)"
    lipo -info "$ROOT/Wayfork/Resources/bin/$bin" | grep -q "arm64" \
        || warn "Wayfork/Resources/bin/$bin has no arm64 slice"
    lipo -info "$ROOT/Wayfork/Resources/bin/$bin" | grep -q "x86_64" \
        || warn "Wayfork/Resources/bin/$bin has no x86_64 slice (Intel Macs will not work)"
done

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
    if [[ -z "$IDENTITY" && "$SKIP_NOTARIZE" -eq 1 ]]; then
        IDENTITY="$(security find-identity -v -p codesigning \
            | awk -F'"' '/Apple Development/ { print $2; exit }')"
    fi
    [[ -n "$IDENTITY" ]] || die "no 'Developer ID Application' identity in the keychain; pass --identity (any identity works with --skip-notarize)"
fi

# The Team ID is the certificate's OU (the "(XXXXXXXXXX)" suffix in the name is the personal
# developer id for individual accounts only). Same logic as scripts/dev-sign.sh.
if [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    CERT_NAME="$(security find-identity -v -p codesigning \
        | awk -F'"' -v h="$(tr '[:lower:]' '[:upper:]' <<<"$IDENTITY")" \
            'index(toupper($0), h) { print $2; exit }')"
    [[ -n "$CERT_NAME" ]] || die "no codesigning identity with SHA-1 $IDENTITY"
else
    CERT_NAME="$IDENTITY"
fi
TEAM_ID="$(security find-certificate -c "$CERT_NAME" -p \
    | openssl x509 -noout -subject -nameopt sep_multiline \
    | sed -n 's/^ *OU=\([A-Z0-9]\{10\}\)$/\1/p' | head -n 1)"
[[ -n "$TEAM_ID" ]] || die "could not determine the Team ID (certificate OU) for '$CERT_NAME'"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    [[ "$CERT_NAME" == "Developer ID Application"* ]] \
        || die "notarization needs a 'Developer ID Application' identity (got '$CERT_NAME'); use --skip-notarize for a local smoke test"
    [[ -n "$PROFILE" ]] \
        || die "no notarytool profile: pass --keychain-profile or set WAYFORK_NOTARY_PROFILE (or --skip-notarize)"
else
    [[ "$CERT_NAME" == "Developer ID Application"* ]] \
        || warn "'$CERT_NAME' is not a Developer ID identity: Gatekeeper will block the download until the quarantine flag is cleared (see README)"
fi

SETTINGS="$(xcodebuild -project "$PROJECT" -scheme Wayfork -configuration Release \
    -showBuildSettings 2>/dev/null)"
VERSION="$(sed -n 's/^ *MARKETING_VERSION = //p' <<<"$SETTINGS" | head -n 1)"
BUILD_NUMBER="$(sed -n 's/^ *CURRENT_PROJECT_VERSION = //p' <<<"$SETTINGS" | head -n 1)"
[[ -n "$VERSION" ]] || die "cannot read MARKETING_VERSION from the project"
if [[ -n "$WANT_VERSION" && "$WANT_VERSION" != "$VERSION" ]]; then
    die "project is at version $VERSION, not $WANT_VERSION (bump MARKETING_VERSION first)"
fi

if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    warn "working tree is not clean; the archive will not match a tagged commit"
fi

mkdir -p "$OUT"

# ---------------------------------------------------------------------------------------------
# Archive

if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
    log "Archiving Wayfork $VERSION ($BUILD_NUMBER) with '$CERT_NAME' (team $TEAM_ID)"
    rm -rf "$ARCHIVE"
    xcodebuild \
        -project "$PROJECT" \
        -scheme Wayfork \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE" \
        -derivedDataPath "$DERIVED" \
        -quiet \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        archive
else
    log "Reusing archive $ARCHIVE"
fi
ARCHIVED_APP="$ARCHIVE/Products/Applications/Wayfork.app"
[[ -d "$ARCHIVED_APP" ]] || die "archive has no Wayfork.app at $ARCHIVED_APP"

rm -rf "$APP"
ditto "$ARCHIVED_APP" "$APP"

# ---------------------------------------------------------------------------------------------
# Sign inside out. The build phase signs the bundled binaries without a timestamp and the
# app's seal covers them, so everything from the leaves up is signed again here: hardened
# runtime, secure timestamp, identifiers kept.

log "Signing"
for bin in sing-box openvpn; do
    [[ -x "$APP/$BIN_REL/$bin" ]] || die "$bin is not in the bundle"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        --identifier "com.wayfork.bin.$bin" "$APP/$BIN_REL/$bin"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --preserve-metadata=identifier,entitlements,flags "$APP/$DAEMON_REL"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --preserve-metadata=identifier,entitlements,flags "$APP"

log "Verifying"
codesign --verify --deep --strict --verbose=1 "$APP"
for path in "$APP" "$APP/$DAEMON_REL" "$APP/$BIN_REL/sing-box" "$APP/$BIN_REL/openvpn"; do
    codesign --verify --strict "$path"
    # Capture first: `grep -q` closing the pipe early would fail the pipeline under pipefail.
    INFO="$(codesign -dvv "$path" 2>&1)"
    grep -q '^Timestamp=' <<<"$INFO" || die "no secure timestamp on $path"
    grep -q 'flags=.*runtime' <<<"$INFO" || die "hardened runtime is off on $path"
done
BAKED_TEAM="$(otool -X -P "$APP/$DAEMON_REL" | plutil -extract WayforkTeamID raw -o - -)"
[[ "$BAKED_TEAM" == "$TEAM_ID" ]] \
    || die "daemon Info.plist has WayforkTeamID='$BAKED_TEAM', expected '$TEAM_ID'"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || die "bundle says version $APP_VERSION, project $VERSION"
lipo -info "$APP/Contents/MacOS/Wayfork" | grep -q "x86_64" \
    || warn "the app is not universal ($(lipo -info "$APP/Contents/MacOS/Wayfork"))"

# ---------------------------------------------------------------------------------------------
# Notarize + staple

notarize() {
    local file="$1" transcript="$OUT/notarytool-$(basename "$file").log"
    log "Notarizing $(basename "$file") (profile '$PROFILE')"
    if ! xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --timeout 45m \
        | tee "$transcript"; then
        die "notarytool submit failed; see $transcript"
    fi
    if ! grep -q '^ *status: Accepted' "$transcript"; then
        local id
        id="$(sed -n 's/^ *id: //p' "$transcript" | head -n 1)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
        die "notarization of $(basename "$file") was not accepted; see $transcript"
    fi
}

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    ZIP="$OUT/Wayfork-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
else
    log "Skipping notarization (--skip-notarize)"
fi

# ---------------------------------------------------------------------------------------------
# DMG

DMG="$OUT/Wayfork-$VERSION.dmg"
STAGING="$OUT/dmg-root"
log "Packaging $(basename "$DMG")"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Wayfork.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Wayfork $VERSION" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

log "Done"
echo "  version:  $VERSION ($BUILD_NUMBER), team $TEAM_ID"
echo "  app:      $APP"
echo "  dmg:      $DMG"
echo "  sha256:   $(cut -d' ' -f1 "$DMG.sha256")"
echo "  archive:  $ARCHIVE"
if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo "  NOT notarized: users must run"
    echo "            xattr -dr com.apple.quarantine /Applications/Wayfork.app"
    echo "            after copying the app (README, \"Install\")"
fi
echo "  next:     git tag -a v$VERSION -m 'Wayfork $VERSION' && git push origin v$VERSION,"
echo "            then attach the .dmg and .sha256 to the GitHub release"
