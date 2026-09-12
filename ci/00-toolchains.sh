#!/usr/bin/env bash
# Stage 00 — toolchains/
#
# Produces:
#   toolchains/llvm-mingw-<ver>-ucrt-macos-universal/   (aarch64-w64-mingw32 PE toolchain)
#   toolchains/llvm-ios-build/lib/*.a                   (LLVM 15.0.7 cross-built for ios-arm64)
#
# Both are prerequisites of build/dxmt-ios. Recipe follows
# build/dxmt-ios/README.md "Prerequisites" steps 2 and 3.
#
# This is by far the slowest stage (LLVM cross-build ~1-3h cold). It is
# cached in CI on the (LLVM_VERSION, LLVM_MINGW_VERSION) pair.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_macos

# ---------------------------------------------------------------- llvm-mingw
group_start "llvm-mingw $LLVM_MINGW_VERSION"
if [ -x "$LLVM_MINGW_DIR/bin/aarch64-w64-mingw32-clang" ]; then
    log "already present: $LLVM_MINGW_DIR"
else
    log "downloading $LLVM_MINGW_URL"
    curl -fL --retry 3 "$LLVM_MINGW_URL" | tar -xJ -C "$TOOLCHAINS"
    [ -x "$LLVM_MINGW_DIR/bin/aarch64-w64-mingw32-clang" ] \
        || die "llvm-mingw extracted but $LLVM_MINGW_DIR/bin/aarch64-w64-mingw32-clang is missing"
fi
group_end

# DXMT's meson cross file resolves toolchains through the submodule root.
if [ -d "$DXMT_SRC" ] && [ ! -e "$DXMT_SRC/toolchains" ]; then
    ln -s ../../toolchains "$DXMT_SRC/toolchains"
    log "linked research/dxmt/toolchains -> ../../toolchains"
fi

# ------------------------------------------------------------- LLVM for iOS
if [ -d "$LLVM_IOS_BUILD/lib" ] && [ -n "$(ls -A "$LLVM_IOS_BUILD"/lib/*.a 2>/dev/null)" ]; then
    log "llvm-ios-build already populated — skipping LLVM build"
    exit 0
fi

group_start "llvm-project $LLVM_VERSION source"
if [ ! -d "$LLVM_SRC/llvm" ]; then
    log "fetching llvm-project llvmorg-$LLVM_VERSION (shallow)"
    git clone --depth 1 --branch "llvmorg-$LLVM_VERSION" \
        https://github.com/llvm/llvm-project.git "$LLVM_SRC"
fi

# README step 3: Apple's ld rejects --gc-sections. AddLLVM.cmake only reaches
# for -dead_strip when the system is "Darwin"; iOS needs the same branch.
ADDLLVM="$LLVM_SRC/llvm/cmake/modules/AddLLVM.cmake"
if grep -q 'MATCHES "Darwin|iOS"' "$ADDLLVM"; then
    log "AddLLVM.cmake already patched"
else
    log "patching AddLLVM.cmake: Darwin -> Darwin|iOS"
    /usr/bin/sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/g' "$ADDLLVM"
    grep -q 'MATCHES "Darwin|iOS"' "$ADDLLVM" || die "AddLLVM.cmake patch did not apply"
fi
group_end

# Stage 1 — host llvm-tblgen. The iOS stage cannot run its own tblgen.
group_start "LLVM host stage (llvm-tblgen)"
if [ ! -x "$LLVM_HOST_BUILD/bin/llvm-tblgen" ]; then
    cmake -S "$LLVM_SRC/llvm" -B "$LLVM_HOST_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_ENABLE_PROJECTS="" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF
    cmake --build "$LLVM_HOST_BUILD" --target llvm-tblgen
fi
[ -x "$LLVM_HOST_BUILD/bin/llvm-tblgen" ] || die "host llvm-tblgen was not produced"
group_end

# Stage 2 — iOS target libs, reusing the host tblgen.
group_start "LLVM iOS stage (static libs)"
cmake -S "$LLVM_SRC/llvm" -B "$LLVM_IOS_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_DXMT" \
    -DLLVM_TABLEGEN="$LLVM_HOST_BUILD/bin/llvm-tblgen" \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_BUILD_UTILS=Off \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_UTILS=Off \
    -DLLVM_INCLUDE_TOOLS=Off \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF
cmake --build "$LLVM_IOS_BUILD"
group_end

ls "$LLVM_IOS_BUILD"/lib/*.a >/dev/null 2>&1 \
    || die "LLVM iOS stage finished but produced no static libs in $LLVM_IOS_BUILD/lib"

log "stage 00 complete"
log "  llvm-mingw:     $LLVM_MINGW_DIR"
log "  llvm-ios-build: $(ls "$LLVM_IOS_BUILD"/lib/*.a | wc -l | tr -d ' ') static libs"
