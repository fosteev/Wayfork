#!/usr/bin/env bash
#
# Builds Wayfork signed with the developer's Apple Development identity. SMAppService
# refuses ad-hoc signed apps, so this is the way to run a debug build with the daemon.
#
# The Team ID of the identity is passed as DEVELOPMENT_TEAM, which Xcode expands into the
# daemon's embedded Info.plist (`WayforkTeamID`) — the daemon uses it in the code-signing
# requirement for XPC clients and bundled binaries (docs/design/05-daemon.md).
#
# Usage: scripts/dev-sign.sh [--configuration Debug|Release] [--identity "<name or SHA-1>"]
#
#   WAYFORK_CODESIGN_IDENTITY   default for --identity; otherwise the first
#                               "Apple Development" identity in the keychain is used.
# Output: build/DerivedData/Build/Products/<configuration>/Wayfork.app

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Debug"
IDENTITY="${WAYFORK_CODESIGN_IDENTITY:-}"
DERIVED="$ROOT/build/DerivedData"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development/ { print $2; exit }')"
    [[ -n "$IDENTITY" ]] || die "no 'Apple Development' identity in the keychain; pass --identity"
fi

# The Team ID is the certificate's OU. The "(XXXXXXXXXX)" suffix in the identity name is the
# developer's personal ID, which only coincides with the Team ID for individual accounts.
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

log "Building $CONFIGURATION with identity '$IDENTITY' (team $TEAM_ID)"
xcodebuild \
    -project "$ROOT/Wayfork/Wayfork.xcodeproj" \
    -scheme Wayfork \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -quiet \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build

APP="$DERIVED/Build/Products/$CONFIGURATION/Wayfork.app"
DAEMON="$APP/Contents/MacOS/WayforkDaemon"
[[ -d "$APP" ]] || die "build product not found at $APP"

log "Verifying signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign --verify --strict "$DAEMON"
for bin in sing-box openvpn; do
    if [[ -x "$APP/Contents/Resources/bin/$bin" ]]; then
        codesign --verify --strict "$APP/Contents/Resources/bin/$bin"
    else
        echo "  note: $bin is not bundled (run scripts/fetch-bins.sh)"
    fi
done

BAKED_TEAM="$(otool -X -P "$DAEMON" | plutil -extract WayforkTeamID raw -o - -)"
[[ "$BAKED_TEAM" == "$TEAM_ID" ]] \
    || die "daemon Info.plist has WayforkTeamID='$BAKED_TEAM', expected '$TEAM_ID'"

log "Signed: $APP"
echo "  app:    $(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p') / $(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p')"
echo "  daemon: $(codesign -dv "$DAEMON" 2>&1 | sed -n 's/^TeamIdentifier=//p') / $(codesign -dv "$DAEMON" 2>&1 | sed -n 's/^Identifier=//p') (WayforkTeamID=$BAKED_TEAM)"
