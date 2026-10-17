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
./build.sh clean                         # remove bin/work/build/cache and refresh sources next run
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
Re-running is safe: already-applied patches are detected and skipped. Successfully built components are also cached under `build/artifacts/` and may be reused by another release only when the cache can identify matching source, patches, recipe, target flags, toolchain, environment, and dependencies. The cache is trusted local storage: checksums detect accidental corruption, not malicious tampering. Cache entry publication is an atomic directory rename after a complete manifest is staged; restoring multiple files into the flat `bin/<mc>/` directory uses rollback on failure but is not atomically visible as one group. Each release still receives its own copied files; later component failures do not discard earlier completed artifacts. Set `ARTIFACTS=/path/to/cache` to use another artifact-cache directory; an external override is not removed by `./build.sh clean`. The default artifact cache is removed by `clean` together with generated outputs, work trees, and cached source mirrors. Patches and release configuration remain untouched. On Solaris, the builder clones each new mirror from inside `cache/` to avoid an old Git argument-parsing issue with absolute mirror paths.

Run the portable synthetic cache checks with `sh tests/cache.sh`. They validate cache metadata and fabricated ELF headers, not native compiler output. The historical 26.3 `WRONG-ELF` report has no measured header values, so its cause remains unconfirmed; actual SPARCV9 ELF inspection and a full build still require a Solaris SPARC host.

## Solaris launchers

Build a release first, then run its entry point, for example `launch/launch-1.20.1.sh` or `launch/launch-26.3.sh`. There is one wrapper for each baseline in `versions.conf`; wrappers share `launch/launcher.py` and use Mojang version JSON metadata to assemble the classpath and version-specific arguments. The patched `bin/<version>/lwjgl.jar` is placed before the stock LWJGL core jar, and `bin/<version>` is used for both `java.library.path` and `org.lwjgl.librarypath`.

The launcher reads `MINECRAFT_HOME` if set; otherwise it prefers `~/Library/Application Support/minecraft` when present, then `~/.minecraft`. Exact local version JSON files are used as-is; missing version metadata is downloaded from Mojang's official version manifest. Missing client and applicable library jars are downloaded from their official metadata URLs into the normal `versions/` and `libraries/` paths, and the asset index and referenced assets are fetched as needed. Downloads use temporary files and are published only after any metadata-provided size and SHA-1 checks pass; unsafe paths/URLs or failed verification stop launch. Native classifier jars are skipped because this project supplies Solaris natives in `bin/<version>`. Set `JAVA_HOME` to a compatible Solaris JDK; the JSON Java major version is checked. `MC_NATIVE_DIR` can override the default repository `bin/<version>` directory. `SOLARIS_LIBRARY_PATH`, `MESA_LIBRARY_PATH`, and `VULKAN_LIBRARY_PATH` can add shared-library directories to `LD_LIBRARY_PATH`; existing `LD_LIBRARY_PATH` is preserved. In particular, `VULKAN_LIBRARY_PATH` helps the runtime linker find the Vulkan loader library but does not select an ICD or prove a compatible Vulkan driver/device is installed. The [SparcSolarisPorts Vulkan project](https://github.com/SparcSolarisPorts/vulkan) documents a tested Solaris 11.4/SPARC T8 stack with loader 1.3.250 under `/opt/vulkan-1.3.250` (`libvulkan.so`) and Mesa 21.3.8 Lavapipe under `/opt/mesa-lavapipe-21.3.8-wsi` (`libvulkan_lvp.so`). For that loader generation the project uses `VK_DRIVER_FILES` (preferred) or `VK_ICD_FILENAMES` to select the ICD **manifest JSON**, not the ICD library; its exact installed manifest path depends on the installation, so verify it on the host. Example: `VULKAN_LIBRARY_PATH=/opt/vulkan-1.3.250/lib` and `VK_DRIVER_FILES=/path/to/verified-lavapipe-icd.json`. Those prefixes are examples from that project, not defaults injected by this launcher. It reports whether `VULKAN_LIBRARY_PATH`, `VK_DRIVER_FILES`, and `VK_ICD_FILENAMES` are set; this is configuration reporting, not a functional Vulkan probe. That project reports Vulkan interface negotiation warnings even in some successful initialization/presentation tests, and describes the stack as experimental, so distinguish such a warning from a failed loader or device enumeration. `MESA_GL_VERSION_OVERRIDE` is optional and is not forced by default.

Set `MC_USERNAME` to override the default display name. Mojang's modern arguments require valid authentication/session values; this helper does not authenticate accounts or manufacture credentials. Set the needed `MC_UUID`, `MC_ACCESS_TOKEN`, `MC_CLIENT_ID`, and related values from a trusted authenticated launcher environment, or launch through a compatible authenticated launcher. Sensitive values are not printed. The launcher is experimental and has not been runtime-validated on SPARC Solaris; actual native loading and game startup must be tested on the target host. A Vulkan-loader warning and the reported fatal OpenAL `ALC.create` failure are separate observations; neither currently proves the cause of the other. Vulkan needs target-host verification of the loader, ICD manifest, and device enumeration, while OpenAL needs its own backend/device diagnostics. The SparcSolarisPorts Vulkan guide provides a reference Solaris 11.4/SPARC T8 stack and probe commands; following its installation-specific instructions is required, and its documented loader/driver interface warning may be non-fatal if probes succeed.

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
| `libjemalloc.so` | jemalloc 5.3.0 | all; `je_cv_os_unfair_lock=no --with-jemalloc-prefix=je_ --disable-initial-exec-tls`, with the generated background-thread define removed (Solaris lacks jemalloc's affinity API) |
| `libopenal.so` | OpenAL Soft 1.23.1 | all; Solaris + OSS backends, RTKit/DBus off, Solaris GNU version-script compatibility enabled, dynamic GCC C++ runtime by default |
| `libfreetype.so` | FreeType `VER-2-13-2` (1.21), `VER-2-14-1` (26.1/26.2), `VER-2-14-3` (26.3+) | 1.21 and newer (LWJGL >= 3.3.3) |
| `libshaderc.so`, `libspirv-cross.so` | LWJGL-CI/shaderc, LWJGL-CI/SPIRV-Cross, tag `LWJGL-3.4.3` | 26.2+ |
| `libSDL3.so` | libsdl-org/SDL `release-3.4.18` | 26.3+ only, Vulkan enabled on Solaris, DBus disabled to avoid Linux DBus headers |

jemalloc and OpenAL Soft keep a stable C ABI (so does GLFW), so every release
pins the same ref by default; override `*_REF` in `version.env` for an exact match.
The LWJGL tag is the one thing that differs per release:

| Minecraft | LWJGL | patch set |
|---|---|---|
| 26.3, 26.4 | 3.4.3 | lwjgl3, sdl3, shaderc, spvc |
| 26.1, 26.2 | 3.4.1 | lwjgl3, glfw, shaderc, spvc (26.2) |
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
it is judged correctly. Only components listed in each release's `COMPONENTS`
value are checked; stale patch directories copied from another release are
ignored. Output is a release x component matrix (`OK`, `3WAY`, `FAIL n/m`,
`NOREF`, `NOFETCH`) followed by the failing hunks, grouped when several
releases share the same ref. Exit status is non-zero if anything fails. The
builder itself applies exactly the same way and stops at the first patch that
does not apply; `ALLOW_3WAY=1` lets it use `--3way` results.

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

## SPARC JDK and hardware notes

For newer SPARC/Solaris JDK builds, see the
[SparcSolarisPorts OpenJDK downloads and build information](https://asbestosstar.egoism.jp/sparcsolarisports/openjdk).
For Vulkan setup on SPARC Solaris, also see the
[SparcSolarisPorts Vulkan guide](https://github.com/SparcSolarisPorts/vulkan).
Choose a JDK that matches the Minecraft version and LWJGL requirements; it must
provide a working SPARCV9 `javac`, `java`, and JNI headers, including
`$JAVA_HOME/include/jni.h`.

The SPARC T8 and M8 systems are strong candidates for running Minecraft on
Solaris. Oracle's [SPARC T8-1 data sheet](https://www.oracle.com/a/ocom/docs/sparc-t8-1-ds-3864201.pdf)
and the [SPARC performance discussion](https://www.solaris.wtf/blog/sparc-performance-still-rulez/)
describe benchmark results in which SPARC systems delivered about twice the
Java throughput of some contemporary competitor systems and led on per-core
critical jOPS. These are workload- and configuration-dependent benchmark
claims, not a guarantee for every Minecraft setup; compare the exact JVM,
Minecraft version, memory configuration, and workload before making a
purchasing or SLA decision.

SPARC T8/M8 processors also include Oracle's Data Analytics Accelerator (DAX)
software-in-silicon features. See [Oracle's DAX overview video](https://www.youtube.com/watch?v=fxm_Wf7SlXE&xstg=CAMSBhUDzO3xHw%3D%3D)
for background. DAX is not required by this builder and does not replace the
need for a compatible SPARC JDK or Solaris native libraries.

## Requirements

gcc/g++ (`-m64`), **GNU make (`gmake`)**, cmake, git, the **Apache Ant package** (`ant`), a SPARCV9 JDK, autoconf
(jemalloc from git), autoconf/automake/libtool (libffi from git), X11 dev headers.
The libffi configure step disables Automake dependency tracking because older
Solaris Automake setups cannot bootstrap the generated dependency fragments.
All project builds use `gmake`; install it and keep it available as `gmake` in
`PATH` (or set `MAKE=/path/to/gmake`). Install the Apache Ant package and keep
`ant` available in `PATH`; LWJGL's native and Java build uses it directly.
GNU make builds automatically use the online processor count (`getconf`, then
`psrinfo`, with a fallback of 4); set `JOBS=N` to override it, for example
`JOBS=32 ./build.sh 26.3`. `JOBS` must be a positive integer and controls GNU
make jobs for CMake, libffi, and jemalloc builds. LWJGL Ant's SunOS config has
its own parallel compiler/linker tasks, whose concurrency is managed by Ant.
C++ native libraries use the shared GCC runtime by default, so the matching
SPARC64 `libstdc++.so` and its Solaris runtime path must be available when
running Minecraft. Set `LWJGL_SUNOS_STATIC_RUNTIME=1` only when the matching
SPARC64 static `libgcc.a` and `libstdc++.a` archives are installed and you
intentionally want them linked into LWJGL/OpenAL. Override `CC CXX MAKE CMAKE
ARCH_FLAGS CFLAGS CXXFLAGS LDFLAGS JOBS`, `LWJGL_ANT_TARGETS`,
`LWJGL_ANT_ARGS`, `OPENAL_CMAKE_ARGS`, `SDL3_CMAKE_ARGS` as needed.

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
