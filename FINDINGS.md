# Madeira — build findings

Notes from getting an unsigned IPA out of this project. Everything here was
verified against the repos, the build scripts, or a green CI run; guesses are
labelled as guesses.

Target device for these notes: **iPad Pro M4 (2024), 8 GB, SideStore**.

---

## TL;DR — how to actually get an IPA

**Fastest (done):** download the artifact from a fork that already builds green.

```bash
gh run download 34646764866 --repo nicogig/Madeira -n Madeira
```

Local copy: `downloads/Madeira-nicogig-34646764866.ipa`
`sha256 29b17474e23cc6e4cfecc5f5b8687cd93faac525933a9e53ba00a17a6111e38f`
62,785,590 bytes · Mach-O arm64 · unsigned · artifact expires **2026-09-18**.

**Reproducible (done):** run `.github/workflows/build-madeira-ipa.yml` on this fork.

Run `34684104750` went green in **37m45s on completely cold caches** — the LLVM
cross-build is far cheaper than it looks, because it builds no targets, tools or
utils. Budget well under an hour, not the several I first assumed.

Local copy: `downloads/Madeira-own-34684104750.ipa`
`sha256 17b522303473e3b16e856de3c6e301bfce5a46c45c67b867947e6fb6f8d9a62e`

**Cross-check:** 300 of 306 files are byte-identical between that build and
nicogig's independent one. The 6 that differ are the main binary (same size,
18,031,368 bytes — differing only by build host, timestamps and UUID), the four
DXMT PE DLLs meson rebuilds each run, and one license text file. Two independent
builds converging is also what clears the downloaded IPA.

Both produce an unsigned IPA. Signing and entitlements are on you.

---

## What this project is

Wine (ARM64EC) + FEX-Emu (x86-64 → ARM64) + DXMT (D3D11 → Metal), running as a
single Mach process on iOS with wineserver as a thread rather than a process.
GPL-3.0-or-later. Upstream: `willfaust/madeira`, default branch `main`.

Three submodules, all forks carrying the iOS work — upstream clones will not build:

| submodule | repo | branch |
|---|---|---|
| `FEX` | `willfaust/FEX` | `ios-port-2607` |
| `wine` | `willfaust/wine` | `ios-build` |
| `research/dxmt` | `willfaust/dxmt` | `ios-port` |

---

## The build chain

Nine stages. Seven are the maintainer's own committed scripts; two he ran by hand.

| # | stage | recipe lives in | committed? |
|---|---|---|---|
| 1 | llvm-mingw + LLVM 15.0.7 for iOS | `build/dxmt-ios/README.md` (prose) | yes |
| 2 | wine → `wine/build-macos` | **nowhere** | **no** |
| 3 | FEX → `FEX/build-ios` | **nowhere** | **no** |
| 4 | gnutls/nettle/gmp | `build/gnutls-ios/build.sh` | yes |
| 5 | freetype | `build/freetype-ios/build.sh` | yes |
| 6 | ntdll unix side | `build/ntdll-unix/build.sh` | yes |
| 7 | win32u unix side | `build/win32u-unix/build.sh` | yes |
| 8 | wineserver | `build/wineserver/build.sh` | yes, but see below |
| 9 | DXMT PE + unix | `build/dxmt-ios/README.md` + `build.sh` | yes |

Then `xcodebuild` → `Payload/` → `.ipa`.

Maintainer's own ordering hint, `STEAM_CEF_HANDOFF.md:256`: ntdll-unix ·
wineserver · win32u-unix · dxmt-ios + libtool · app via xcodebuild.

---

## The gap: outputs are gitignored, and some inputs were never published

`.gitignore` excludes every intermediate archive. A clean checkout is missing:

```
app/Madeira/libntdll_unix.a
app/Madeira/libwin32u_unix.a
app/Madeira/libwineserver.a
app/Madeira/libdxmt_combined.a
FEX/build-ios/**
wine/build-macos/**
toolchains/**
app/Madeira/x86_64-vcruntime/*.dll
```

What **is** committed and does not need rebuilding — worth knowing, because the
docs are stale about it:

- `libgmp.a`, `libgnutls.a`, `libhogweed.a`, `libnettle.a`
- `app/libdxmt_unix.a`
- **All eight DXMT PE DLLs**, in both `aarch64-windows/` and `arm64ec-windows/`.
  `build/dxmt-ios/README.md` says "Both are gitignored — rebuild via the steps
  below." That is **wrong** for the PE DLLs; only `libdxmt_combined.a` is ignored.
- `app/Madeira/arm64ec-windows/xtajit64.dll` — so there is no reason to build
  `FEX/build-arm64ec` in CI.

---

## Recipe 1 — the Wine configure line, RECOVERED

Upstream README points at the Wine submodule; the Wine fork's `configure.ac` is
byte-identical to stock Wine 11.4 and its README is stock upstream. Dead pointer.

A seven-agent sweep of all four repos — docs, complete 194-commit history,
deleted files, code search, gists, issues, PRs — found nothing.

**It was inside the build artifact all along**, as `wine/build-macos/config.log`:

```sh
../configure --enable-win64 --disable-tests --without-x --without-freetype
```

Wine 11.4, Autoconf 2.72. Empirically backed — this is the invocation from a run
that produced a working IPA.

Notes:

- **No `--enable-archs` at all.** `configure.ac:392-393` defaults
  `cross_archs=$HOST_ARCH`, which on an aarch64 Darwin host is `aarch64` — that,
  not `--enable-win64`, is why aarch64 PE libs come out.
- `--enable-win64` is effectively a **no-op** here. Its only uses are an
  `x86_64*|amd64*` host `-m32` guard and a `--with-wine64` exclusion check;
  neither fires on aarch64 Darwin. Do not read it as selecting the PE arch.
- `--enable-archs=arm64ec` would silently pull in x86_64
  (`configure.ac:406`), requiring an `x86_64-w64-mingw32` compiler too.

**A full `make` cannot succeed on a macOS host, by design.**
`wine/dlls/win32u/dibdrv/bitblt.c:1065` declares `extern void ios_srcwatch_arm(...)`
with no weak attribute — its two siblings at :1038 and :1051 *are* weak. It is
defined only in `build/ntdll-unix/signal_arm64_ios.c:7345`, a Madeira iOS file
that never enters a host Wine build. So `win32u.so` is a hard undefined-symbol
failure. Let `make` fail and verify the artifacts you actually consume:
`tools/winebuild/winebuild`, `dlls/ntdll/aarch64-windows/libntdll.a`,
`libs/winecrt0/aarch64-windows/libwinecrt0.a`, plus the generated headers.

**Hidden hard dependency:** `build/ntdll-unix/build.sh:111` hardcodes
`-I$REPO_ROOT/wine/build-arm64ec/include`, because (per the maintainer's comment
at :108) `dwrite.h` and `dwrite_3.h` are widl-generated and only exist in that
tree. A build that only creates `build-macos` fails later on an
unrelated-looking error. Fix: `ln -sfn build-macos wine/build-arm64ec`.

---

## Recipe 2 — the FEX cmake line, NOT FOUND

The most thoroughly established absence of the four:

- `Data/CMake/` has `toolchain_aarch64 / mingw / x86_32 / x86_64` — no iOS file.
- No `CMakePresets.json`. No iOS script in `Data/nix/` or `Scripts/`.
- `git grep` across **all three branches** for `build-ios`, `iphoneos`, `xcrun`,
  `CMAKE_OSX_SYSROOT`, `CMAKE_SYSTEM_NAME.*iOS`: zero hits.
- All 57 fork commit messages read: zero mentions of cmake/ninja/toolchain/sysroot.
- Nothing added-then-deleted (`git log --diff-filter=D`).
- `FEX/CLAUDE.md` and `FEX/AGENTS.md` are each **one line**, an AI-contribution
  policy. They are not build docs. (I assumed otherwise. I was wrong.)
- `willfaust/FEX`: 0 issues, 0 PRs, 0 releases, 0 tags, 0 Actions runs.
- `.gitignore` has carried `FEX/build-ios/` since the repo's first commit `2ae4f69`.

What **is** real, from maintainer commit `fce78ce` ("iOS/ARM64 port of FEXCore
for jailed iOS devices"):

- Root `CMakeLists.txt:64` was patched to accept `CMAKE_SYSTEM_NAME STREQUAL "iOS"`,
  so `-DCMAKE_SYSTEM_NAME=iOS` is supported, not a hack.
- `CMakeLists.txt:329` force-disables jemalloc/rpmalloc under `if (APPLE)`.
  `libJemallocLibs.a` is still produced — `FEXCore/Source/CMakeLists.txt:302`
  declares it unconditionally, just with no rpmalloc linked.

Flags to get right:

- `-DCMAKE_SYSTEM_PROCESSOR=arm64` — load-bearing. CMake leaves it empty for iOS
  and FEX's processor check then hard-fails.
- `-DBUILD_TESTING=OFF`. There is **no** `BUILD_TESTS` option; passing it is inert.
- `-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` — CMake's compiler probe
  otherwise tries to link an iOS executable.
- Do **not** pass `-DFEX_IOS_HOST_BUILD=ON`. It is read only under `Source/`,
  gated `if (MINGW)` / `if (NOT APPLE)`, and governs the ARM64EC PE build
  (`xtajit64.dll`) — a different deliverable that already ships prebuilt.

**Known fork bug you must patch.**
`FEXCore/Source/Utils/ArchHelpers/Arm64.cpp` defines `IosLogUnimplementedCASPAL`
at :689 and calls Win32 `VirtualQuery` / `MEMORY_BASIC_INFORMATION` at :709 —
outside every `#ifdef FEX_IOS_HOST` guard (nearest closes at :634). The working
workflow stubs it out. If stage 3 dies there, it's a fork bug, not your flags.

The seven archives `app/Madeira.xcodeproj` links by relative path — the
`build-ios` directory name and this layout are load-bearing:

```
FEX/build-ios/FEXCore/Source/libFEXCore.a
FEX/build-ios/FEXCore/Source/libFEXCore_Base.a
FEX/build-ios/FEXCore/Source/libJemallocLibs.a
FEX/build-ios/External/fmt/libfmt.a
FEX/build-ios/External/cephes/libcephes_128bit.a
FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a
FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a
```

---

## Recipe 3 — `libwineserver.a`, unrecoverable but buildable

`build/wineserver/build.sh` is a **patch-over** build. It copies an existing
`app/Madeira/libwineserver.a`, compiles the iOS `*_ios.c` files, swaps object
members in with `ar r`, then runs an `objcopy` symbol-rename sweep. With no base
archive it exits: `ERROR: No base libwineserver.a found`.

That base:

- was never tracked — `git log --all -- '*libwineserver.a'` is empty across all
  194 commits;
- predates commit #1 — the same bail-out is in the script's **first** commit `b398b80`;
- probably came from `wine-ios-build/`, a pre-submodule directory that appears in
  `.gitignore` under "Superseded build dirs" and was never published;
- has lost provenance even for the maintainer. His own comment: the archive
  carried a hand-inserted `sock.o` whose **source was lost**.

**It is not special, though.** It is every `wine/server/*.c` (43 files) compiled
for ios-arm64, and `build/wineserver/build.sh:25-44` spells out the exact
`CC_FLAGS`. Compile them all with those flags, `ar rcs` the result, and the patch
pass runs on top. That is what both the working workflow and
`ci/05-wineserver-base.sh` do.

About 18 members get replaced afterwards (`request main mach unicode fd object
async process window user mapping class region queue winstation thread sock`).
Those have iOS variants precisely *because* the upstream versions do not compile
for iOS, so failures among them are expected. Failures outside that set become
undefined symbols at app link time.

One detail: keep `-include wineserver_ios_kill.h` in the base flags. The PR #5
seeding step drops it.

---

## Recipe 4 — DXMT, documented by the maintainer

`build/dxmt-ios/README.md` carries the full PE recipe and it is current — the
cross file `willfaust/dxmt:build-aarch64-win.txt` has exactly one commit and pins
the same `llvm-mingw-20260421`. No drift.

Two gaps in it:

- The **arm64ec** pass is undocumented. `build-arm64ec-win.txt` exists in the dxmt
  fork and the repo ships four arm64ec DXMT DLLs of different sizes from their
  aarch64 twins — but the invocation is written down nowhere. Not needed: those
  DLLs are committed.
- The "both are gitignored" line is stale (see above).

**Undocumented blocker:** `build/dxmt-ios/shader-headers/` is gitignored and is
only ever produced by a dxmt meson `airconv` target that Madeira never invokes —
but `airconv_context.cpp` is the only file that includes `air_msad.h`,
`air_samplepos.h`, `air_tessellation.h`. Generate them yourself:

```sh
xcrun -sdk macosx metal -o X.air -c X.metal -std=metal3.1 --target=air64-apple-macos14.0
xxd -n X -i X.air X.h
```

---

## Other undocumented prerequisites

- **freetype is not a submodule** and is gitignored, yet `build/win32u-unix/build.sh`
  and `build/ntdll-unix/build.sh` both reference `research/freetype/include`.
  Clone per `build/freetype-ios/build.sh:7`:
  `git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype`
- **MSVC runtime DLLs** are Microsoft-authored and not redistributable here, so
  `app/Madeira/x86_64-vcruntime/*.dll` is gitignored. They can be carved out of
  `https://aka.ms/vs/17/release/vc_redist.x64.exe` — it is a Burn bundle with the
  payload cab appended after the UX cab (invisible to 7-Zip's PE handler), and MSI
  file keys carry a `.dll_amd64` suffix with arm64 twins in a sibling cab.
- **`ContentView.swift` uses `glassEffect()`**, which needs the iOS 26 SDK. On an
  older Xcode it must be patched out.
- **LLVM iOS build must be pruned before caching** to `lib/*.a` and `include/`,
  plus `llvm-project/llvm/include`. Unpruned it is many GB and blows the 10 GB
  per-repo Actions cache budget — the cache then never restores and every run
  rebuilds LLVM.

---

## The Xcode project

- **No shared scheme** is committed → use `-target Madeira`, not `-scheme`.
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set with **no `.xcassets`** present.
- `DEVELOPMENT_TEAM = UT49TA9TA4` is upstream's team; clear it for unsigned builds.
- `TARGETED_DEVICE_FAMILY = "1,2"` — **iPad is a shipping target**, not compatibility mode.
- `IPHONEOS_DEPLOYMENT_TARGET = 17.0`.

Unsigned build and package:

```sh
xcodebuild -project app/Madeira.xcodeproj -target Madeira -configuration Release \
  -sdk iphoneos -derivedDataPath out/DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  ASSETCATALOG_COMPILER_APPICON_NAME="" build

mkdir -p Payload
cp -R out/DerivedData/Build/Products/Release-iphoneos/Madeira.app Payload/
zip -qry Madeira.ipa Payload
```

---

## iPad Pro M4 (8 GB) specifics

iPad is explicitly supported. The maintainer already fixed an iPad layout bug —
`ContentView.swift:867` notes `NavigationView` defaults to a **split view** on
iPad and forced the whole UI into a sidebar/detail arrangement it was never laid
out for; it is `NavigationStack` now. No hardcoded iPhone resolutions anywhere;
`UIScreen.main.scale` and `maximumFramesPerSecond` are read at runtime.

Relative to the A15 / iPhone 13 Pro the project was developed on, the M4 brings
more RAM, a much stronger GPU, and far better sustained thermals — the last
matters as much as peak, since a phone throttles hard within minutes. README says
most titles "reach gameplay at low frame rates" on the A15.

Two iPad-only wins:

- `UIApplicationSupportsIndirectInputEvents = YES` → Magic Keyboard trackpad gives
  real pointer input to Windows games.
- `CADisableMinimumFrameDurationOnPhone = true` → not pinned to 60 Hz.

**Entitlements.** `Madeira.entitlements` ships `increased-memory-limit`,
`allow-jit`, `get-task-allow` — but **not** `extended-virtual-addressing`, which
the app's own UI hints about at runtime ("Tip: Use GetMoreRam to inject
extended-virtual-addressing"). On 8 GB that one is worth injecting at signing time.

Note `com.apple.security.cs.allow-jit` is macOS-only and **never granted on iOS**
— the code says so explicitly at `ContentView.swift:1081`. Real JIT comes purely
from the debugger attach (StikDebug). Do not read a missing badge as broken.

Free Apple ID → profile expires after 7 days, reinstall weekly. The app container
survives reinstall, so prefixes and saves persist.

---

## Provenance of the workflow in this fork

`.github/workflows/build-madeira-ipa.yml` is **not original work**. Lineage:

1. `margooey` opened [PR #5](https://github.com/willfaust/madeira/pull/5) against
   upstream — a complete 673-line workflow, 21 iterations. Closed unmerged, zero
   maintainer comments, head fork since deleted.
2. `nicogig/Madeira` adopted it. Run `34646764866` is green and produced the
   59 MB IPA referenced above.
3. Copied here unmodified, with attribution, under GPL-3.0-or-later.

Keep it in sync with upstream `nicogig/Madeira` rather than editing locally — it
is a known-green configuration.

Related but **not** evidence of anything the maintainer did:
`intraducine/iridium` is a separate AGPL project vendoring the same source
revisions with more detailed prepare scripts, but its own docs say the recipes
"have not been compiled on a clean runner", every IPA run concludes `failure`,
and its FEX target list omits `JemallocLibs`, which the pbxproj links.

`125hz/Madeira` is an active fork that appears to build, but its `.xtool/`
directory — containing `configure-wine.sh` and `build-fex.sh` — is gitignored and
unpublished. Asking them to publish those two scripts is the single highest-yield
remaining lead for the FEX cmake line.

---

## Genuinely unobtainable

1. **The FEX `build-ios` cmake line.** Exhaustively established absence.
2. **The original `libwineserver.a`.** Predates the repo; provenance lost even by
   the maintainer. Cannot be recovered in principle — but can be rebuilt.
3. **The arm64ec DXMT meson line.** Cross file committed, invocation not. Not needed.

The maintainer's local scripts live at `/Users/willfaust/Documents/ios-pc-game-claude/`
— leaked in `build/x64-tests/build.sh:7` and `scripts/deploy-thumper.sh:12` — and
are published nowhere.

Upstream has issues enabled. [#3](https://github.com/willfaust/madeira/issues/3)
asks for exactly a GitHub Actions script, [#2](https://github.com/willfaust/madeira/issues/2)
asks for the IPA, and [#6](https://github.com/willfaust/madeira/issues/6) is
"Support for M4/M series chips on ipad". He has never responded to a single issue
or PR in any of his repos.

---

## Mistakes made getting here

Recorded so they are not repeated.

1. **Said macOS runners would cost money.** They are free for public repos; the
   10x multiplier is private-repo only.
2. **Built a CI pipeline from scratch before checking whether one existed.** A
   proven workflow had been sitting in a closed upstream PR the whole time.
3. **Cached the entire `toolchains/` tree.** Many GB, over the 10 GB budget — the
   cache would never have restored and every run would rebuild LLVM.
4. **Assumed `FEX/CLAUDE.md` was build documentation** because the project is
   AI-assisted. It is a one-line contribution policy.
5. **Spent a seven-agent sweep hunting the Wine configure line** that was sitting
   in `wine/build-macos/config.log` inside the downloadable build artifact. Check
   the artifacts of a green build before searching source history.

The sweep was not worthless — it produced the FEX flag corrections, the
`build-arm64ec` include dependency, the `ios_srcwatch_arm` link-failure mechanism,
and the "DXMT PE DLLs are committed" correction. But the cheap check should have
come first.

---

## Windows Defender false positive

`Payload/Madeira.app/aarch64-windows/cmd.exe` trips
`Behavior:Win32/DefenseEvasion.A!ml` if you extract the IPA on Windows. It is a
false positive, and Defender will silently **delete the copy in your git clone**
too, breaking a local build.

Evidence it is benign: PE machine type is `0xAA64` (ARM64 — it cannot execute on
x86-64 Windows at all), it carries `Wine builtin DLL`, `WINEDEBUG` and 26 `wine`
symbols, and it is byte-identical to what upstream tracks
(`sha256 385a6f2dcd70cd987d0b515eed6c7e630fd782136abe29f3207f2e5c3019a2e6`). The
`!ml` suffix means a machine-learning heuristic, not a signature — it fires on a
file named `cmd.exe` appearing somewhere unexpected.

You do not need to extract the IPA; sideloaders take the `.ipa` as-is. If a local
build needs the file back: `git checkout -- app/Madeira/aarch64-windows/cmd.exe`,
after excluding the path from real-time scanning. Note an exclusion also covers
Wine's `explorer.exe`, `iexplore.exe` and `conhost.exe` in the same folder, which
trip the same name-based heuristics.

---

## Local artifacts

```
downloads/Madeira-own-34684104750.ipa       built from this fork (unsigned, arm64)
downloads/Madeira.entitlements              entitlements plist for the signer
downloads/Madeira-nicogig-34646764866.ipa   the IPA (unsigned, arm64)
downloads/nicogig/                          that run's .err files, meson logs,
                                            fex.log, and wine config.log
ci/                                         superseded stage scripts, kept as
                                            readable explanation + local Mac use
.github/workflows/build-madeira-ipa.yml     the build that actually runs
```
