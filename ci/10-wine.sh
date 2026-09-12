#!/usr/bin/env bash
# Stage 10 — wine/build-macos
#
# Configures and builds the Wine fork on the macOS host. Everything
# downstream reads out of this tree:
#   * build/ntdll-unix/build.sh   -> build-macos/include/config.h, build-macos/dlls/ntdll
#   * build/win32u-unix/build.sh  -> build-macos/include, build-macos/dlls/win32u
#   * build/wineserver/build.sh   -> build-macos/include
#   * build/dxmt-ios (meson PE)   -> -Dwine_build_path=../../wine/build-macos
#
# The upstream README does not publish the exact configure line ("see the
# Wine submodule for the original configure"), so the invocation below is a
# best-effort reconstruction. If it does not match, drop your own recipe in
# ci/overrides/wine-configure.sh — it is run with CWD = wine/build-macos and
# must leave a usable Makefile behind.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_macos
need_submodule wine

# Wine needs bison 3.x; macOS ships 2.3. Homebrew keg-only installs win.
for p in /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin \
         /opt/homebrew/opt/flex/bin /usr/local/opt/flex/bin; do
    [ -d "$p" ] && PATH="$p:$PATH"
done
# llvm-mingw supplies the aarch64 / arm64ec PE compilers.
[ -d "$LLVM_MINGW_DIR/bin" ] && PATH="$LLVM_MINGW_DIR/bin:$PATH"
export PATH

command -v bison >/dev/null || die "bison not found (brew install bison)"
case "$(bison --version | head -1)" in
    *" 3."*|*" 4."*) : ;;
    *) warn "bison $(bison --version | head -1) looks too old — Wine wants 3.x" ;;
esac

WINE_ARCHS="${WINE_ARCHS:-aarch64,arm64ec}"

mkdir -p "$WINE_BUILD"

group_start "wine configure"
if [ -f "$WINE_BUILD/Makefile" ] && [ -f "$WINE_BUILD/include/config.h" ]; then
    log "wine/build-macos already configured — skipping configure"
elif try_override wine-configure; then
    :
else
    ( cd "$WINE_BUILD" && "$WINE_SRC/configure" \
        --enable-archs="$WINE_ARCHS" \
        --disable-tests \
        --without-x \
        --without-freetype \
        --without-vulkan \
        --without-opengl )
fi
[ -f "$WINE_BUILD/include/config.h" ] \
    || die "wine configure did not produce build-macos/include/config.h"
group_end

group_start "wine make"
if try_override wine-make; then
    :
else
    # A full `make` also links the macOS host loader, which is not needed
    # here and is the most fragile part of a Wine-on-macOS build. Downstream
    # stages only consume generated headers plus the PE import libs, so
    # tolerate a partial build and verify the artifacts we actually need.
    make -C "$WINE_BUILD" -j"$(sysctl -n hw.ncpu)" || \
        warn "wine make exited non-zero — checking for the artifacts we need anyway"
fi
group_end

missing=0
for f in "$WINE_BUILD/include/config.h" "$WINE_BUILD/include/wine/server_protocol.h"; do
    [ -f "$f" ] || { warn "missing: ${f#$REPO_ROOT/}"; missing=1; }
done
[ "$missing" -eq 0 ] || die "wine build is incomplete — downstream stages will fail"

log "stage 10 complete: ${WINE_BUILD#$REPO_ROOT/}"
