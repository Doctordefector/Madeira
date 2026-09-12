#!/usr/bin/env bash
# Stage 05 — bootstrap a base app/Madeira/libwineserver.a
#
# build/wineserver/build.sh is a patch-over build: it copies an existing
# archive and swaps ~18 object members into it. It cannot create the archive,
# and upstream gitignores it, so a clean checkout has nothing to patch.
#
# But the base is not secret — it is just every wine/server/*.c compiled for
# ios-arm64, and build.sh already spells out the exact flags. This compiles
# the full set with those same flags and archives the result. build.sh then
# runs on top and replaces the members it cares about.
#
# The ~18 files build.sh replaces have iOS variants precisely because the
# upstream versions do not compile for iOS, so failures among those are
# expected and harmless. Failures OUTSIDE that set are real and reported.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_macos
need_submodule wine

BUILD_DIR="$REPO_ROOT/build/wineserver"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"
OBJ_DIR="$BUILD_DIR/base-obj"
APP_LIB="$APP_RES/libwineserver.a"
SDK="$(ios_sdk)"

[ -f "$WINE_BUILD/include/config.h" ] || die "run ci/10-wine.sh first"

if [ -f "$APP_LIB" ]; then
    log "app/Madeira/libwineserver.a already present — nothing to bootstrap"
    exit 0
fi

# Byte-for-byte the CC_FLAGS array from build/wineserver/build.sh. Keep them
# in sync: the patch step replaces members inside this archive, so the base
# and the patches must be compiled the same way.
CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$IOS_MIN" -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_BUILD/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration
)

# Members build.sh replaces afterwards — a miss here costs nothing.
REPLACED="request main mach unicode fd object async process window user mapping class region queue winstation thread sock"
is_replaced() { case " $REPLACED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

rm -rf "$OBJ_DIR"; mkdir -p "$OBJ_DIR"

group_start "compiling wine/server/*.c for ios-arm64"
ok=0; skipped=""; broken=""
for src in "$WINE_SRC"/server/*.c; do
    name="$(basename "$src" .c)"
    printf '  %-20s ' "$name"
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$OBJ_DIR/$name.o" \
            2>"$OBJ_DIR/$name.err"; then
        echo "OK"; ok=$((ok+1))
    elif is_replaced "$name"; then
        echo "skip (build.sh replaces it)"; skipped="$skipped $name"
    else
        echo "FAILED"; broken="$broken $name"
    fi
done
group_end

[ "$ok" -gt 0 ] || die "nothing compiled — check $OBJ_DIR/*.err"

if [ -n "$broken" ]; then
    warn "these are not in build.sh's replacement list and still failed:$broken"
    warn "the app link will report them as undefined symbols; see $OBJ_DIR/<name>.err"
    if [ "${WINESERVER_BASE_STRICT:-0}" = "1" ]; then
        die "WINESERVER_BASE_STRICT=1 and $(echo $broken | wc -w | tr -d ' ') file(s) failed"
    fi
fi

xcrun -sdk iphoneos ar rcs "$APP_LIB" "$OBJ_DIR"/*.o
log "stage 05 complete: $ok objects -> app/Madeira/libwineserver.a ($(wc -c < "$APP_LIB" | tr -d ' ') bytes)"
[ -n "$skipped" ] && log "  skipped (replaced downstream):$skipped"
log "  build/wineserver/build.sh will now patch this archive."
