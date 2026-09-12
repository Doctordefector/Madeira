> **Superseded — not wired to any workflow.**
>
> `.github/workflows/build-madeira-ipa.yml` is the build that actually runs. It
> comes from nicogig/Madeira (originally margooey's PR #5 against upstream) and
> is a known-green configuration that produces a working IPA.
>
> These scripts were written before that was found. They are kept because they
> are readable stage-by-stage and runnable on a local Mac, and because
> `05-wineserver-base.sh` keeps the `-include wineserver_ios_kill.h` flag that
> the PR #5 seeding step drops. Everything else here is worse than the workflow:
> no LLVM cache pruning (would exceed the 10 GB repo budget), no MSVC runtime
> extraction, no FEX `Arm64.cpp` patch, no airconv shader-header generation, and
> a Wine `configure` line that has never been proven to work.
>
> Use the workflow. Read these for explanation.

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
./ci/05-wineserver-base.sh # app/Madeira/libwineserver.a base  (run after 10, before 30)
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

Runner minutes cost nothing here: standard GitHub-hosted runners, macOS
included, are free for public repositories. Keep this fork public and the
whole pipeline is free. The limits that do apply are per-job (6 h) and
concurrency, not billing.

### 2. The base `libwineserver.a`

Handled automatically — but worth knowing about, because it is the part most
likely to need attention.

`build/wineserver/build.sh` is a *patch-over* build: it copies an existing
`app/Madeira/libwineserver.a`, compiles the iOS-specific `*_ios.c` files, swaps
those object members into the archive with `ar r`, then runs an `objcopy`
symbol-rename sweep over every member. With no base archive it stops at:

```
ERROR: No base libwineserver.a found
```

That archive is in upstream's `.gitignore` and is published nowhere. It is not
special, though — it is every `wine/server/*.c` compiled for ios-arm64, and
`build/wineserver/build.sh` already spells out the exact flags. So
`ci/05-wineserver-base.sh` compiles the full set with those same flags and
archives the result, and stage 30 falls back to it when no archive is supplied.

The ~18 members `build.sh` replaces have iOS variants precisely because the
upstream versions do not build for iOS, so failures among those are expected
and skipped. Anything failing *outside* that set is reported and will surface
as undefined symbols at app link time — run with `WINESERVER_BASE_STRICT=1` to
stop on it instead.

To use a known-good archive rather than a rebuilt one:

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
