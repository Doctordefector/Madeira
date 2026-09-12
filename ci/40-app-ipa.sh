#!/usr/bin/env bash
# Stage 40 — xcodebuild + unsigned .ipa
#
# Madeira cannot ship signed from CI: it needs the JIT / increased-memory /
# extended-virtual-addressing entitlements and a debugger attach, so it is
# sideloaded and re-signed on the user's own Apple ID (StikDebug, AltStore,
# Sideloadly...). This stage therefore builds with signing disabled and
# packages the raw Payload, which is what every sideloader expects.
#
# app/Madeira.xcodeproj ships no shared scheme, so this uses -target.
# It also sets ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon while carrying no
# .xcassets, so the asset-catalog step is cleared out here.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_macos

DERIVED="$OUT_DIR/DerivedData"
PRODUCTS="$DERIVED/Build/Products/${XCODE_CONFIG}-iphoneos"
APP_BUNDLE="$PRODUCTS/${XCODE_TARGET}.app"
IPA="$OUT_DIR/${XCODE_TARGET}-unsigned.ipa"

# Fail early and legibly rather than deep inside a linker error.
group_start "prerequisite check"
missing=0
for lib in libdxmt_combined.a libntdll_unix.a libwin32u_unix.a libwineserver.a \
           libgmp.a libgnutls.a libhogweed.a libnettle.a; do
    [ -f "$APP_RES/$lib" ] || { warn "missing app/Madeira/$lib"; missing=1; }
done
for lib in FEXCore/Source/libFEXCore.a FEXCore/Source/libFEXCore_Base.a \
           FEXCore/Source/libJemallocLibs.a External/fmt/libfmt.a \
           External/cephes/libcephes_128bit.a \
           External/xxhash/cmake_unofficial/libxxhash.a \
           External/SoftFloat-3e/libsoftfloat_3e.a; do
    [ -f "$FEX_BUILD/$lib" ] || { warn "missing FEX/build-ios/$lib"; missing=1; }
done
[ "$missing" -eq 0 ] || die "run ci/20-fex.sh and ci/30-native-libs.sh first"

# Not fatal — the app links and installs without these, but Wine will fail to
# start most real titles at runtime. Microsoft-authored, not redistributable
# here, so they are never in CI.
if [ -z "$(ls -A "$APP_RES/x86_64-vcruntime" 2>/dev/null)" ]; then
    warn "app/Madeira/x86_64-vcruntime is empty — the MSVC runtime DLLs are not"
    warn "redistributable and must be added yourself; games needing them will fail at runtime"
fi
group_end

group_start "xcodebuild ($XCODE_CONFIG, unsigned)"
rm -rf "$DERIVED"
xcodebuild \
    -project "$XCODE_PROJECT" \
    -target "$XCODE_TARGET" \
    -configuration "$XCODE_CONFIG" \
    -sdk iphoneos \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ASSETCATALOG_COMPILER_APPICON_NAME="" \
    build
group_end

[ -d "$APP_BUNDLE" ] || die "no app bundle at ${APP_BUNDLE#$REPO_ROOT/}"

group_start "package .ipa"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP_BUNDLE" "$STAGE/Payload/"
# Sideloaders re-sign with their own identity; ship the entitlements next to
# the ipa so whoever signs it knows which ones the app needs.
cp "$APP_RES/Madeira.entitlements" "$OUT_DIR/Madeira.entitlements"
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )
rm -rf "$STAGE"
group_end

log "stage 40 complete"
log "  ipa:          ${IPA#$REPO_ROOT/}  ($(du -h "$IPA" | cut -f1 | tr -d ' '))"
log "  entitlements: out/Madeira.entitlements"
log ""
log "  Unsigned. Re-sign with your own Apple ID before installing, and attach"
log "  StikDebug for JIT — see the project README."
