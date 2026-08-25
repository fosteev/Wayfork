#!/usr/bin/env bash
#
# Fetches the pinned sing-box release and builds a fully static openvpn (OpenSSL, lz4, lzo)
# for every architecture in WAYFORK_ARCHS, then places universal binaries into
# Wayfork/Resources/bin/ (git-ignored; copied into the app bundle at build time).
#
# Usage: scripts/fetch-bins.sh [--clean]
#
#   WAYFORK_ARCHS="arm64"       architectures to build (default: "arm64 x86_64")
#   WAYFORK_BUILD_DIR=<path>    scratch directory (default: build/bins)
#   --clean                     wipe the scratch directory first
#
# Requirements: Xcode command line tools (clang, make, lipo), curl, perl (OpenSSL).
# No Homebrew packages are needed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

OUT_DIR="$ROOT/Wayfork/Resources/bin"
BUILD_DIR="${WAYFORK_BUILD_DIR:-$ROOT/build/bins}"
DL_DIR="$BUILD_DIR/downloads"
ARCHS="${WAYFORK_ARCHS:-arm64 x86_64}"
MACOS_MIN="14.0"
JOBS="$(sysctl -n hw.ncpu)"
# openvpn's configure stamps `git rev-parse HEAD` into its version string when it finds a
# repository above the source tree — keep it from discovering Wayfork's own .git.
export GIT_CEILING_DIRECTORIES="$BUILD_DIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$DL_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# download <file> <sha256> <url> [<mirror-url>...]
download() {
    local file="$1" expected="$2" path url
    shift 2
    path="$DL_DIR/$file"
    if [[ -f "$path" && "$(sha256 "$path")" == "$expected" ]]; then
        return
    fi
    for url in "$@"; do
        log "Downloading $file"
        if curl --fail --location --silent --show-error --retry 3 --output "$path.tmp" "$url"; then
            if [[ "$(sha256 "$path.tmp")" == "$expected" ]]; then
                mv "$path.tmp" "$path"
                return
            fi
            rm -f "$path.tmp"
            die "checksum mismatch for $file downloaded from $url"
        fi
        rm -f "$path.tmp"
        echo "  download from $url failed, trying next mirror" >&2
    done
    die "could not download $file"
}

# extract <tarball> <dir>: unpack into a fresh directory, dropping the top-level folder
extract() {
    rm -rf "$2"
    mkdir -p "$2"
    tar -xzf "$1" -C "$2" --strip-components=1
}

# run <log-name> <cmd...>: run quietly, show the log tail on failure
run() {
    local name="$1" logfile
    shift
    logfile="$BUILD_DIR/$name.log"
    if ! "$@" >"$logfile" 2>&1; then
        echo "--- $logfile (tail) ---" >&2
        tail -n 40 "$logfile" >&2
        die "$name failed; full log: $logfile"
    fi
}

host_triple() {
    case "$1" in
        arm64) echo aarch64-apple-darwin ;;
        x86_64) echo x86_64-apple-darwin ;;
        *) die "unsupported architecture: $1" ;;
    esac
}

go_arch() {
    case "$1" in
        arm64) echo arm64 ;;
        x86_64) echo amd64 ;;
        *) die "unsupported architecture: $1" ;;
    esac
}

openssl_target() {
    case "$1" in
        arm64) echo darwin64-arm64-cc ;;
        x86_64) echo darwin64-x86_64-cc ;;
        *) die "unsupported architecture: $1" ;;
    esac
}

# lipo_or_copy <output> <slice>...
lipo_or_copy() {
    local out="$1"
    shift
    if [[ $# -eq 1 ]]; then
        cp -f "$1" "$out"
    else
        lipo -create "$@" -output "$out"
    fi
    chmod 755 "$out"
}

BUILD_TRIPLE="$(host_triple "$(uname -m)")"

# ---------------------------------------------------------------------------------------
# sing-box: official release binaries, combined into a universal binary
# ---------------------------------------------------------------------------------------

fetch_sing_box() {
    local arch name sha_var dir slices=()
    for arch in $ARCHS; do
        name="sing-box-${SING_BOX_VERSION}-darwin-$(go_arch "$arch").tar.gz"
        sha_var="SING_BOX_SHA256_$(tr '[:lower:]' '[:upper:]' <<<"$arch")"
        download "$name" "${!sha_var}" \
            "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/$name"
        dir="$BUILD_DIR/sing-box-$arch"
        extract "$DL_DIR/$name" "$dir"
        slices+=("$dir/sing-box")
    done
    lipo_or_copy "$OUT_DIR/sing-box" "${slices[@]}"
    log "sing-box $SING_BOX_VERSION -> $OUT_DIR/sing-box"
}

# ---------------------------------------------------------------------------------------
# openvpn: static build per architecture, then lipo
# ---------------------------------------------------------------------------------------

build_openssl() {
    local arch="$1" prefix="$2" src="$BUILD_DIR/openssl-$arch"
    [[ -f "$prefix/lib/libssl.a" ]] && return
    log "Building OpenSSL $OPENSSL_VERSION ($arch)"
    extract "$DL_DIR/openssl-${OPENSSL_VERSION}.tar.gz" "$src"
    (
        cd "$src"
        run "openssl-$arch-configure" ./Configure "$(openssl_target "$arch")" \
            --prefix="$prefix" --libdir=lib \
            no-shared no-module no-tests no-docs no-apps \
            "-mmacosx-version-min=$MACOS_MIN"
        run "openssl-$arch-make" make -j "$JOBS" build_sw
        run "openssl-$arch-install" make install_sw
    )
}

build_lz4() {
    local arch="$1" prefix="$2" src="$BUILD_DIR/lz4-$arch"
    [[ -f "$prefix/lib/liblz4.a" ]] && return
    log "Building lz4 $LZ4_VERSION ($arch)"
    extract "$DL_DIR/lz4-${LZ4_VERSION}.tar.gz" "$src"
    # lz4's Makefile derives CFLAGS itself; the arch/version flags go through CC.
    run "lz4-$arch-make" make -C "$src/lib" -j "$JOBS" install \
        PREFIX="$prefix" BUILD_SHARED=no \
        CC="cc -arch $arch -mmacosx-version-min=$MACOS_MIN"
}

build_lzo() {
    local arch="$1" prefix="$2" src="$BUILD_DIR/lzo-$arch"
    [[ -f "$prefix/lib/liblzo2.a" ]] && return
    log "Building lzo $LZO_VERSION ($arch)"
    extract "$DL_DIR/lzo-${LZO_VERSION}.tar.gz" "$src"
    (
        cd "$src"
        run "lzo-$arch-configure" ./configure \
            --build="$BUILD_TRIPLE" --host="$(host_triple "$arch")" \
            --prefix="$prefix" --enable-static --disable-shared \
            CFLAGS="-arch $arch -mmacosx-version-min=$MACOS_MIN -O2"
        run "lzo-$arch-make" make -j "$JOBS"
        run "lzo-$arch-install" make install
    )
}

build_openvpn() {
    local arch="$1" prefix="$2" src="$BUILD_DIR/openvpn-$arch"
    [[ -x "$prefix/bin/openvpn" ]] && return
    log "Building openvpn $OPENVPN_VERSION ($arch)"
    extract "$DL_DIR/openvpn-${OPENVPN_VERSION}.tar.gz" "$src"
    (
        cd "$src"
        run "openvpn-$arch-configure" ./configure \
            --build="$BUILD_TRIPLE" --host="$(host_triple "$arch")" \
            --prefix="$prefix" \
            --with-crypto-library=openssl \
            --enable-lz4 --enable-lzo \
            --disable-plugins --disable-plugin-auth-pam --disable-plugin-down-root \
            --disable-dco --disable-dns-updown-by-default \
            --disable-unit-tests --disable-debug \
            CFLAGS="-arch $arch -mmacosx-version-min=$MACOS_MIN -O2" \
            LDFLAGS="-arch $arch -mmacosx-version-min=$MACOS_MIN" \
            OPENSSL_CFLAGS="-I$prefix/include" \
            OPENSSL_LIBS="-L$prefix/lib -lssl -lcrypto" \
            LZ4_CFLAGS="-I$prefix/include" \
            LZ4_LIBS="-L$prefix/lib -llz4" \
            LZO_CFLAGS="-I$prefix/include" \
            LZO_LIBS="-L$prefix/lib -llzo2"
        run "openvpn-$arch-make" make -j "$JOBS"
        mkdir -p "$prefix/bin"
        cp -f src/openvpn/openvpn "$prefix/bin/openvpn"
    )
}

fetch_openvpn() {
    local arch prefix slices=()
    download "openvpn-${OPENVPN_VERSION}.tar.gz" "$OPENVPN_SHA256" \
        "https://github.com/OpenVPN/openvpn/releases/download/v${OPENVPN_VERSION}/openvpn-${OPENVPN_VERSION}.tar.gz" \
        "https://swupdate.openvpn.org/community/releases/openvpn-${OPENVPN_VERSION}.tar.gz"
    download "openssl-${OPENSSL_VERSION}.tar.gz" "$OPENSSL_SHA256" \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
    download "lz4-${LZ4_VERSION}.tar.gz" "$LZ4_SHA256" \
        "https://github.com/lz4/lz4/releases/download/v${LZ4_VERSION}/lz4-${LZ4_VERSION}.tar.gz"
    download "lzo-${LZO_VERSION}.tar.gz" "$LZO_SHA256" \
        "https://www.oberhumer.com/opensource/lzo/download/lzo-${LZO_VERSION}.tar.gz" \
        "https://deb.debian.org/debian/pool/main/l/lzo2/lzo2_${LZO_VERSION}.orig.tar.gz"

    for arch in $ARCHS; do
        prefix="$BUILD_DIR/prefix-$arch"
        mkdir -p "$prefix"
        build_openssl "$arch" "$prefix"
        build_lz4 "$arch" "$prefix"
        build_lzo "$arch" "$prefix"
        build_openvpn "$arch" "$prefix"
        slices+=("$prefix/bin/openvpn")
    done
    lipo_or_copy "$OUT_DIR/openvpn" "${slices[@]}"
    strip "$OUT_DIR/openvpn"
    log "openvpn $OPENVPN_VERSION -> $OUT_DIR/openvpn"
}

# ---------------------------------------------------------------------------------------

fetch_sing_box
fetch_openvpn

log "Result"
lipo -archs "$OUT_DIR/sing-box" | sed 's/^/  sing-box: /'
lipo -archs "$OUT_DIR/openvpn" | sed 's/^/  openvpn:  /'
if [[ " $ARCHS " == *" $(uname -m) "* ]]; then
    "$OUT_DIR/sing-box" version | head -n 1 | sed 's/^/  /'
    "$OUT_DIR/openvpn" --version | head -n 1 | sed 's/^/  /'
    if otool -L "$OUT_DIR/openvpn" | grep -q -E 'libssl|libcrypto|liblz4|liblzo'; then
        die "openvpn is dynamically linked against a crypto/compression library"
    fi
fi
