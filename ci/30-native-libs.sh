#!/usr/bin/env bash
# Stage 30 — the gitignored static archives + DXMT PE DLLs the app links.
#
# Produces (all listed in .gitignore, so a clean checkout never has them):
#   app/Madeira/libdxmt_combined.a
#   app/Madeira/libntdll_unix.a
#   app/Madeira/libwin32u_unix.a
#   app/Madeira/libwineserver.a          <-- see BASE ARCHIVE note below
#   app/Madeira/aarch64-windows/{d3d11,dxgi,winemetal,d3d10core}.dll
#
# BASE ARCHIVE: build/wineserver/build.sh is a *patch-over* build. It copies
# an existing app/Madeira/libwineserver.a and swaps individual .o members
# into it; with no base archive it exits 1 ("No base libwineserver.a found").
# That base is gitignored and is not published anywhere, so a clean checkout
# cannot produce it. Supply it out of band:
#   * drop it at ci/prebuilt/libwineserver.a, or
#   * set WINESERVER_BASE_URL to something curl can fetch.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_macos
need_submodule wine
need_submodule research/dxmt

[ -f "$WINE_BUILD/include/config.h" ] || die "run ci/10-wine.sh first (no wine/build-macos/include/config.h)"

[ -d "$LLVM_MINGW_DIR/bin" ] && PATH="$LLVM_MINGW_DIR/bin:$PATH"
for p in /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin \
         /opt/homebrew/bin /usr/local/bin; do
    [ -d "$p" ] && PATH="$p:$PATH"
done
export PATH

# ------------------------------------------------------- freetype (optional)
group_start "freetype for iOS"
FT_DIR="$REPO_ROOT/build/freetype-ios"
if [ -f "$FT_DIR/build/libfreetype.a" ]; then
    log "libfreetype.a already built"
else
    if [ ! -d "$REPO_ROOT/research/freetype" ]; then
        log "cloning freetype VER-2-13-3"
        git clone --depth 1 --branch VER-2-13-3 \
            https://github.com/freetype/freetype.git "$REPO_ROOT/research/freetype"
    fi
    # Non-fatal: win32u only warns "fonts will be disabled" without it.
    "$FT_DIR/build.sh" || warn "freetype build failed — win32u will link without fonts"
fi
group_end

# ------------------------------------------------------------ DXMT (PE side)
group_start "DXMT PE DLLs (meson, aarch64-w64-mingw32)"
DXMT_PE_OUT="$APP_RES/aarch64-windows"
if [ -f "$DXMT_SRC/build-pe/src/d3d11/d3d11.dll" ]; then
    log "build-pe already populated"
elif try_override dxmt-pe; then
    :
else
    [ -e "$DXMT_SRC/toolchains" ] || ln -s ../../toolchains "$DXMT_SRC/toolchains"
    ( cd "$DXMT_SRC" && \
      SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
      PATH="$LLVM_MINGW_DIR/bin:$PATH" \
      meson setup --cross-file build-aarch64-win.txt --native-file build-osx.txt \
                  -Dwine_build_path=../../wine/build-macos build-pe )
    ( cd "$DXMT_SRC" && \
      SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
      PATH="$LLVM_MINGW_DIR/bin:$PATH" \
      meson compile -C build-pe )
fi
for pair in "d3d11/d3d11.dll" "dxgi/dxgi.dll" "winemetal/winemetal.dll" "d3d10/d3d10core.dll"; do
    src="$DXMT_SRC/build-pe/src/$pair"
    [ -f "$src" ] || die "DXMT PE build did not produce $pair"
    cp "$src" "$DXMT_PE_OUT/"
done
log "copied 4 DXMT PE DLLs into app/Madeira/aarch64-windows/"
group_end

# ---------------------------------------------------------- DXMT (unix side)
group_start "libdxmt_combined.a"
if [ -f "$APP_RES/libdxmt_combined.a" ]; then
    log "already present"
else
    ls "$LLVM_IOS_BUILD"/lib/*.a >/dev/null 2>&1 \
        || die "toolchains/llvm-ios-build/lib/*.a missing — run ci/00-toolchains.sh"
    "$REPO_ROOT/build/dxmt-ios/build.sh"
    ( cd "$REPO_ROOT/build/dxmt-ios" && \
      xcrun -sdk iphoneos libtool -static -o libdxmt_combined.a \
          obj/*.o "$LLVM_IOS_BUILD"/lib/*.a )
    cp "$REPO_ROOT/build/dxmt-ios/libdxmt_combined.a" "$APP_RES/"
fi
group_end

# ----------------------------------------------------------------- ntdll unix
group_start "libntdll_unix.a"
"$REPO_ROOT/build/ntdll-unix/build.sh"
[ -f "$APP_RES/libntdll_unix.a" ] || die "build/ntdll-unix/build.sh produced no libntdll_unix.a"
group_end

# ---------------------------------------------------------------- win32u unix
group_start "libwin32u_unix.a"
"$REPO_ROOT/build/win32u-unix/build.sh"
[ -f "$APP_RES/libwin32u_unix.a" ] || die "build/win32u-unix/build.sh produced no libwin32u_unix.a"
group_end

# ------------------------------------------------------------------ wineserver
group_start "libwineserver.a"
if [ ! -f "$APP_RES/libwineserver.a" ]; then
    if [ -f "$CI_DIR/prebuilt/libwineserver.a" ]; then
        log "using base archive from ci/prebuilt/libwineserver.a"
        cp "$CI_DIR/prebuilt/libwineserver.a" "$APP_RES/libwineserver.a"
    elif [ -n "${WINESERVER_BASE_URL:-}" ]; then
        log "fetching base archive from WINESERVER_BASE_URL"
        curl -fL --retry 3 -o "$APP_RES/libwineserver.a" "$WINESERVER_BASE_URL"
    else
        cat >&2 <<'MSG'

[fail] No base libwineserver.a.

build/wineserver/build.sh does not build the wineserver from scratch — it
copies an existing app/Madeira/libwineserver.a and replaces individual object
members inside it. That base archive is gitignored and is not published, so a
clean checkout cannot produce one.

Supply it one of these ways, then re-run:
  * commit or mount it at  ci/prebuilt/libwineserver.a
  * set  WINESERVER_BASE_URL=<url>  (a repo variable/secret works in CI)

MSG
        exit 1
    fi
fi
"$REPO_ROOT/build/wineserver/build.sh"
group_end

log "stage 30 complete — archives in app/Madeira:"
for a in libdxmt_combined.a libntdll_unix.a libwin32u_unix.a libwineserver.a; do
    printf '  %-24s %s bytes\n' "$a" "$(wc -c < "$APP_RES/$a" | tr -d ' ')"
done
