#!/usr/bin/env bash
# Shared configuration for the Madeira CI build stages.
# Sourced by every ci/NN-*.sh script; not meant to be run directly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_DIR="$REPO_ROOT/ci"
OVERRIDES_DIR="$CI_DIR/overrides"
TOOLCHAINS="$REPO_ROOT/toolchains"

# --- versions -----------------------------------------------------------
# Pinned to what build/dxmt-ios/README.md documents. Override via env.
LLVM_MINGW_VERSION="${LLVM_MINGW_VERSION:-20260421}"
LLVM_MINGW_NAME="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal"
LLVM_MINGW_DIR="$TOOLCHAINS/$LLVM_MINGW_NAME"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${LLVM_MINGW_NAME}.tar.xz"

LLVM_VERSION="${LLVM_VERSION:-15.0.7}"
LLVM_SRC="$TOOLCHAINS/llvm-project"
LLVM_HOST_BUILD="$TOOLCHAINS/llvm-host-build"
LLVM_IOS_BUILD="$TOOLCHAINS/llvm-ios-build"

# --- build targets ------------------------------------------------------
IOS_MIN="${IOS_MIN:-17.0}"        # matches IPHONEOS_DEPLOYMENT_TARGET
IOS_MIN_DXMT="${IOS_MIN_DXMT:-18.0}"  # build/dxmt-ios/build.sh uses 18.0
XCODE_CONFIG="${XCODE_CONFIG:-Release}"

WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
FEX_SRC="$REPO_ROOT/FEX"
FEX_BUILD="$FEX_SRC/build-ios"
DXMT_SRC="$REPO_ROOT/research/dxmt"

APP_DIR="$REPO_ROOT/app"
APP_RES="$APP_DIR/Madeira"
XCODE_PROJECT="$APP_DIR/Madeira.xcodeproj"
XCODE_TARGET="Madeira"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"

# --- helpers ------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

group_start() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || log "$*"; }
group_end()   { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::" || true; }

# Run an override script if the user supplied one, else return 1 so the
# caller falls back to the built-in best-effort recipe.
#   try_override wine-configure  ->  ci/overrides/wine-configure.sh
try_override() {
    local name="$1"; shift
    local script="$OVERRIDES_DIR/${name}.sh"
    if [ -x "$script" ]; then
        log "using override: ci/overrides/${name}.sh"
        "$script" "$@"
        return 0
    fi
    return 1
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "this stage needs macOS (xcrun / iphoneos SDK)"
}

ios_sdk() { xcrun --sdk iphoneos --show-sdk-path; }

need_submodule() {
    local path="$1"
    [ -e "$REPO_ROOT/$path/.git" ] || [ -n "$(ls -A "$REPO_ROOT/$path" 2>/dev/null)" ] \
        || die "submodule '$path' is empty — run: git submodule update --init --recursive"
}

mkdir -p "$TOOLCHAINS" "$OUT_DIR"
