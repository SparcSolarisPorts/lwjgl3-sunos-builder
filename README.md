# lwjgl3-sunos-builder

Downloads, patches and builds the native libraries Minecraft needs on
**SPARC Solaris** (SunOS, SPARCV9, big-endian), one script per Minecraft
release (1.13 and newer, main releases only).

```
build.sh                  dispatcher:  ./build.sh list | all | <mc> [component...]
versions.conf             MC release -> LWJGL version (checked by tools/check-versions.sh)
lib/                      shared fetch / patch / build / verify code
mc/<mc>/build.sh          the per-release script
mc/<mc>/version.env       pinned source refs + the list of natives that must exist
mc/<mc>/patches/<comp>/   *.patch applied to that component for that release
tools/                    new-version.sh, check-versions.sh, extract-fork-patches.sh
```

## Usage

```sh
export JAVA_HOME=/path/to/sparcv9-jdk     # needs include/jni.h (LWJGL core)
./build.sh list
./build.sh 1.20.1                         # libffi glfw lwjgl3 jemalloc openal, then verify
./build.sh 26.3                           # libffi lwjgl3 jemalloc openal freetype shaderc spvc sdl3
./build.sh 1.20.1 glfw                    # one component
PREPARE_ONLY=1 ./build.sh 1.20.1          # fetch + patch, don't compile
DRY_RUN=1 ./build.sh 26.3                 # print every command, run nothing
./build.sh all
./build.sh check                          # dry-run every patch set (see below)
```

Output goes to `bin/<mc>/` (flat directory of `.so` files, plus `lwjgl.jar`
rebuilt with the `SUNOS` platform enum). Sources are cloned from a cached bare
mirror in `cache/` into `work/<mc>/`, so your own checkouts are never modified.
Re-running is safe: already-applied patches are detected and skipped.

Run Minecraft with `-Dorg.lwjgl.librarypath=<bin/mc>` and put the rebuilt
`lwjgl.jar` ahead of the stock core jar on the classpath.

`verify` checks every library in `NATIVES` exists **and** is a 64-bit
big-endian SPARCV9 ELF, so an x86 or missing binary fails the build.

## What gets built

The set per release matches what Mojang's version JSONs ship for Linux
(`~/.minecraft/versions/<v>/<v>.json`); `tools/new-version.sh` derives it.

| Library | Source | Releases / notes |
|---|---|---|
| `liblwjgl.so`, `liblwjgl_opengl.so`, `liblwjgl_stb.so` | LWJGL tag for the release | all; `ant`, sources bundled |
| `liblwjgl_tinyfd.so` | LWJGL tag | 1.15 - 26.2 |
| `liblwjgl_vma.so` | LWJGL tag | 26.2+ |
| `libffi.a` (static, internal) | libffi `v3.8.0` | `LWJGL_SUNOS_LIBFFI_A` points at it; LWJGL 3.3+ binds libffi, 3.1.x/3.2.x bind dyncall, which the patch replaces by a small shim (`core/src/main/c/sunos/dyncall_ffi.c`) over the same static libffi |
| `libglfw.so` | glfw/glfw `3.5.1` + the glfw patch | 1.13 - 26.2 (X11 only, Wayland off); not shipped from 26.3 |
| `libjemalloc.so` | jemalloc 5.3.0 | all; `--with-jemalloc-prefix=je_ --disable-initial-exec-tls` |
| `libopenal.so` | OpenAL Soft 1.23.1 | all; Solaris + OSS backends, static libgcc/libstdc++ |
| `libfreetype.so` | FreeType `VER-2-13-2` (1.21), `VER-2-14-1` (26.1/26.2), `VER-2-14-3` (26.3+) | 1.21 and newer (LWJGL >= 3.3.3) |
| `libshaderc.so`, `libspirv-cross.so` | LWJGL-CI/shaderc, LWJGL-CI/SPIRV-Cross, tag `LWJGL-3.4.3` | 26.2+ |
| `libSDL3.so` | libsdl-org/SDL `release-3.4.18` | 26.3+ only, Vulkan enabled on Solaris |

jemalloc and OpenAL Soft keep a stable C ABI (so does GLFW), so every release
pins the same ref by default; override `*_REF` in `version.env` for an exact match.
The LWJGL tag is the one thing that differs per release:

| Minecraft | LWJGL | patch set |
|---|---|---|
| 26.3, 26.4 | 3.4.3 | lwjgl3, sdl3, shaderc |
| 26.1, 26.2 | 3.4.1 | lwjgl3, glfw |
| 1.21 (also 1.20.5+) | 3.3.3 | lwjgl3, glfw |
| 1.19, 1.20, 1.20.1 | 3.3.1 | lwjgl3, glfw |
| 1.15 - 1.18 | 3.2.2 | lwjgl3, glfw (dyncall shim) |
| 1.14 | 3.2.1 | lwjgl3, glfw (dyncall shim) |
| 1.13 | 3.1.6 | lwjgl3, glfw (dyncall shim) |

## Checking which releases the patches apply to

Patches are written against one source tree, but each release pins a different
LWJGL tag, so they will not apply everywhere. Find out without building anything:

```sh
./build.sh check                 # all releases        (= tools/check-patches.sh)
./build.sh check 1.20.1 26.3     # some releases
./build.sh check --3way          # also report patches a 3-way merge could rescue
./build.sh check -v              # per-patch verdicts, including the ones that pass
GLFW_REF=3.4 ./build.sh check    # try a different ref without editing version.env
```

Patches are applied in order to a throw-away index built from the cached
mirror (no checkout, nothing built), so a patch that depends on the one before
it is judged correctly. Output is a release x component matrix (`OK`, `3WAY`,
`FAIL n/m`, `NOREF`, `NOFETCH`) followed by the failing hunks, grouped when
several releases share the same ref. Exit status is non-zero if anything fails.
The builder itself applies exactly the same way and stops at the first patch
that does not apply; `ALLOW_3WAY=1` lets it use `--3way` results.

## Patches

`mc/<mc>/patches/<component>/*.patch`, applied in order with `git apply`
(exact context; `ALLOW_FUZZ=1` falls back to `patch -F3`).

* `lwjgl3/0001-solaris-sunos-sparc.patch`: SunOS/SPARC platform support (new
  `config/sunos/build.xml`, `sparc64` arch, libffi/sparc, `Platform.SUNOS`, X11 and
  dlopen templates). **One port per LWJGL tag family** (3.4.x, 3.3.x, 3.2.x, 3.1.6):
  the source layout differs a lot between them, so the patch of one family does not
  apply to another. `./build.sh check` verifies all of them.
* `glfw/0001-sunos-solaris-illumos.patch`: SunOS/illumos support, X11 default,
  Wayland off. Applied to **upstream** glfw/glfw (the fork already contains it).
* `sdl3/0001-sunos-vulkan.patch` (26.3+): lets `SDL_VULKAN` be enabled on Solaris
  (Wayland is switched off by the build script).
* `shaderc/0001-*.patch` (26.2+): Solaris ld has no `--whole-archive`; uses
  `-z allextract` (set `-DSHADERC_SUNOS_GNU_LD=ON` when gcc uses GNU ld).
* `jemalloc/`, `openal/`: empty; add patches there if a build needs them.

For releases the baseline patch does not fit, derive per-release patches from the
SparcSolarisPorts fork (it tracks `master`) by replaying its commits onto each tag:

```sh
git clone https://github.com/SparcSolarisPorts/lwjgl3 ~/git/lwjgl3
tools/extract-fork-patches.sh lwjgl3 ~/git/lwjgl3 https://github.com/LWJGL/lwjgl3.git 1.20.1
# -> mc/1.20.1/patches/lwjgl3.generated/  (clean replays + SKIPPED.txt for conflicts)
```

Review, then move the good ones into `patches/lwjgl3/` (drop the hand-written
`0001-sunos-platform.patch` if the fork's commit supersedes it). The build
warns if the patched LWJGL tree contains no SunOS handling at all.

## Requirements

gcc/g++ (`-m64`), `gmake`, cmake, git, Apache Ant, a SPARCV9 JDK, autoconf
(jemalloc from git), autoconf/automake/libtool (libffi from git), X11 dev headers. Override `CC CXX MAKE CMAKE
ARCH_FLAGS CFLAGS LDFLAGS JOBS`, `LWJGL_ANT_TARGETS`, `LWJGL_ANT_ARGS`,
`OPENAL_CMAKE_ARGS`, `SDL3_CMAKE_ARGS` as needed.

## Adding a release

```sh
tools/new-version.sh 26.5 3.4.3 --from mc/26.4   # derives natives + refs, copies patches
tools/new-version.sh 26.4 3.4.3 --regen          # rewrite only version.env (keeps patches)
tools/check-versions.sh                          # compare versions.conf with Mojang's JSONs
./build.sh check 26.5
```

## Status / known gaps

* Nothing here was compiled on real SPARC Solaris. The patches are verified to
  apply (`./build.sh check`); the first real `ant` / CMake builds may need tweaks
  (`LWJGL_ANT_TARGETS`, backend flags).
* The 3.1.x/3.2.x dyncall shim implements the call/callback subset LWJGL's generated
  bindings use (struct functions are stubs).
* `libshaderc.so` fetches glslang/SPIRV-Tools with `utils/git-sync-deps` (network
  required unless `SHADERC_SKIP_SYNC=1`).
* The LWJGL pin per release comes from `versions.conf`; confirm with
  `tools/check-versions.sh` (reads Mojang's version JSONs). Releases that ship a
  different LWJGL than their dir (e.g. 1.14.3+ is 3.2.2, 1.20.2-1.20.4 is 3.3.2) can
  use the patch of the nearest dir; override `LWJGL_REF` accordingly.
