# CI build

Builds `Madeira.app` and packages it as an unsigned `.ipa` for sideloading.

Two workflows:

| workflow | what it does | when |
|---|---|---|
| `.github/workflows/build-toolchains.yml` | stage 00 — `llvm-mingw` + LLVM 15.0.7 cross-built for ios-arm64, saved to the Actions cache | once, manually; again only on a version bump |
| `.github/workflows/build-ipa.yml` | stages 10–40 — wine, FEX, native libs, `xcodebuild`, `.ipa` | manual, or on push to `main` |

The stage scripts are plain bash and run the same way on a local Mac:

```sh
./ci/00-toolchains.sh     # toolchains/llvm-mingw-*, toolchains/llvm-ios-build   (hours, once)
./ci/10-wine.sh           # wine/build-macos
./ci/20-fex.sh            # FEX/build-ios/**/*.a
./ci/30-native-libs.sh    # app/Madeira/lib*.a + DXMT PE DLLs
./ci/40-app-ipa.sh        # out/Madeira-unsigned.ipa
```

## Before the first run

### 1. Run the toolchains workflow

`build-ipa.yml` fails fast if the toolchains cache is missing rather than
silently spending hours rebuilding LLVM inside the IPA job.

The cache is large and GitHub caps a repo at 10 GB of Actions cache with LRU
eviction. If IPA builds start failing on the toolchains check again, look at
**Settings → Actions → Caches**.

### 2. Supply a base `libwineserver.a`

This is the one hard blocker for a clean-checkout build.

`build/wineserver/build.sh` is a *patch-over* build: it copies an existing
`app/Madeira/libwineserver.a`, compiles the iOS-specific `*_ios.c` files, swaps
those object members into the archive with `ar r`, then runs an `objcopy`
symbol-rename sweep over every member. With no base archive it stops at:

```
ERROR: No base libwineserver.a found
```

That archive is in upstream's `.gitignore` and is not published anywhere, so
CI cannot regenerate it. Supply it one of two ways:

- set a repository variable `WINESERVER_BASE_URL` to a URL `curl` can fetch, or
- place the file at `ci/prebuilt/libwineserver.a`.

### 3. Microsoft Visual C++ runtime (runtime only, not a build blocker)

`app/Madeira/x86_64-vcruntime/*.dll` is gitignored — those are Microsoft
binaries and not redistributable here. The app builds and installs without
them; games that need them fail at runtime. Stage 40 warns when the directory
is empty.

## Recipes that are reconstructions

Three parts of the chain are the maintainer's local setup and are not
committed upstream. The scripts use documented-looking defaults, and each one
checks its own output and fails with the real artifact path when the guess is
wrong.

| stage | reconstructed | override |
|---|---|---|
| 10 | the Wine `configure` line (README says only "see the Wine submodule") | `ci/overrides/wine-configure.sh`, `ci/overrides/wine-make.sh` |
| 20 | FEX's iOS CMake configure — the fork has iOS sources but no iOS toolchain file | `ci/overrides/fex-configure.sh`, `ci/overrides/fex-build.sh` |
| 30 | DXMT PE meson setup (this one *is* documented, in `build/dxmt-ios/README.md`) | `ci/overrides/dxmt-pe.sh` |

An override is any executable `ci/overrides/<name>.sh`. When present it runs
instead of the built-in recipe, with `REPO_ROOT`, `WINE_SRC`, `WINE_BUILD`,
`FEX_SRC`, `FEX_BUILD` and `IOS_MIN` exported.

## Why the IPA is unsigned

Madeira needs `com.apple.security.cs.allow-jit`, the increased-memory-limit and
extended-virtual-addressing entitlements, and a debugger attach for JIT. It
cannot go through the App Store, and CI has no signing identity worth using —
a free Apple ID's provisioning profile expires after 7 days anyway.

Stage 40 builds with `CODE_SIGNING_ALLOWED=NO` and zips `Payload/Madeira.app`,
which is what AltStore / Sideloadly / StikDebug expect. It also drops
`Madeira.entitlements` next to the `.ipa` so whoever re-signs knows which
entitlements to request.

## Notes on the Xcode project

- No shared scheme is committed, so stage 40 uses `-target Madeira`.
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set but there is no
  `.xcassets`; stage 40 clears the setting.
- `DEVELOPMENT_TEAM = UT49TA9TA4` is upstream's team and is cleared at build time.
- The project links FEX archives by relative path into `FEX/build-ios/`, so
  that directory name is load-bearing — don't rename it.
