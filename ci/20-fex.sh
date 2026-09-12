#!/usr/bin/env bash
# Stage 20 — FEX/build-ios
#
# app/Madeira.xcodeproj links these seven archives by absolute path, so the
# build directory name (build-ios) and the layout inside it both matter:
#
#   FEX/build-ios/FEXCore/Source/libFEXCore.a
#   FEX/build-ios/FEXCore/Source/libFEXCore_Base.a
#   FEX/build-ios/FEXCore/Source/libJemallocLibs.a
#   FEX/build-ios/External/fmt/libfmt.a
#   FEX/build-ios/External/cephes/libcephes_128bit.a
#   FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a
#   FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a
#
# The fork carries iOS source changes but no committed iOS CMake toolchain
# file or configure script, so the cmake line below is a reconstruction.
# Put your own in ci/overrides/fex-configure.sh if it differs; it runs with
# FEX_SRC / FEX_BUILD / IOS_MIN exported.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_macos
need_submodule FEX

export FEX_SRC FEX_BUILD IOS_MIN

REQUIRED_LIBS=(
    "FEXCore/Source/libFEXCore.a"
    "FEXCore/Source/libFEXCore_Base.a"
    "FEXCore/Source/libJemallocLibs.a"
    "External/fmt/libfmt.a"
    "External/cephes/libcephes_128bit.a"
    "External/xxhash/cmake_unofficial/libxxhash.a"
    "External/SoftFloat-3e/libsoftfloat_3e.a"
)

all_present() {
    local l
    for l in "${REQUIRED_LIBS[@]}"; do
        [ -f "$FEX_BUILD/$l" ] || return 1
    done
    return 0
}

if all_present; then
    log "FEX/build-ios already has all seven archives — skipping"
    exit 0
fi

group_start "FEX configure (iOS arm64)"
if try_override fex-configure; then
    :
else
    cmake -S "$FEX_SRC" -B "$FEX_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
        -DBUILD_TESTS=False \
        -DBUILD_THUNKS=False \
        -DENABLE_LTO=False \
        -DENABLE_ASSERTIONS=False \
        -DENABLE_JEMALLOC=True \
        -DENABLE_JEMALLOC_GLIBC_ALLOC=False \
        -DBUILD_FEX_LINUX_TOOLS=False
fi
group_end

group_start "FEX build"
if try_override fex-build; then
    :
else
    # Build only what Xcode links. If a target name has drifted, fall back to
    # the default target set rather than failing on the first miss.
    if ! cmake --build "$FEX_BUILD" --target \
            FEXCore FEXCore_Base JemallocLibs fmt cephes_128bit xxhash softfloat_3e; then
        warn "per-target build failed — retrying with the default target set"
        cmake --build "$FEX_BUILD"
    fi
fi
group_end

missing=()
for l in "${REQUIRED_LIBS[@]}"; do
    [ -f "$FEX_BUILD/$l" ] || missing+=("$l")
done
if [ "${#missing[@]}" -ne 0 ]; then
    warn "FEX built but these archives are not where Xcode expects them:"
    printf '  FEX/build-ios/%s\n' "${missing[@]}" >&2
    warn "locate the real outputs with: find FEX/build-ios -name '*.a'"
    die "stage 20 incomplete"
fi

log "stage 20 complete: all seven FEX archives present"
