#!/usr/xpg4/bin/sh
# Per-component build steps. Sourced by lib/driver.sh after version.env.
# Every step: fetch pinned source -> apply mc/<ver>/patches/<comp>/ -> build
# -> stage the native into $OUT.  PREPARE_ONLY=1 stops before compiling.

# ------------------------------------------------------------------ libffi
# Static, PIC libffi that LWJGL's config/sunos/build.xml links into
# liblwjgl.so. It refuses to run unless LWJGL_SUNOS_LIBFFI_A names the archive.
comp_libffi() {
  need git "$MAKE" "$CC"
  _src=$WORK/src/libffi
  prepare libffi "$LIBFFI_URL" "$LIBFFI_REF" "$_src" "$PATCHES/libffi"
  [ -z "${PREPARE_ONLY:-}" ] || { log "libffi prepared at $_src"; return 0; }
  cache_identity libffi "$_src" "$PATCHES/libffi" "static=on;pic=on;disable-dependency-tracking;CFLAGS=$CFLAGS;LDFLAGS=$LDFLAGS"
  cache_restore libffi libffi.a
  if [ "$CACHE_HIT" -eq 1 ]; then
    LWJGL_SUNOS_LIBFFI_A=$OUT/libffi.a
    printf '%s\n' "$LWJGL_SUNOS_LIBFFI_A" > "$WORK/libffi.path"
    export LWJGL_SUNOS_LIBFFI_A
    log "libffi cache path: $LWJGL_SUNOS_LIBFFI_A"
    return 0
  fi
  ( cd "$_src" 2>/dev/null || is_dry
    # git checkouts need the autotools; release tarballs ship configure.
    if is_dry || [ ! -x ./configure ]; then run autoreconf -fi; fi
    run env CC="$CC" CFLAGS="$ARCH_FLAGS -fPIC -O2 $CFLAGS" LDFLAGS="$ARCH_FLAGS $LDFLAGS" \
      ./configure --disable-shared --enable-static --with-pic --disable-docs \
      --disable-multi-os-directory --disable-dependency-tracking
    run "$MAKE" -j "$JOBS" )
  if is_dry; then LWJGL_SUNOS_LIBFFI_A=$_src/.libs/libffi.a; else
    _libffi_a=$(find "$_src" -name libffi.a -type f 2>/dev/null | head -1)
    [ -n "$_libffi_a" ] || die "libffi.a not produced under $_src"
    mkdir -p "$OUT"
    cp "$_libffi_a" "$OUT/libffi.a"
    LWJGL_SUNOS_LIBFFI_A=$OUT/libffi.a
    printf '%s\n' "$LWJGL_SUNOS_LIBFFI_A" > "$WORK/libffi.path"
    cache_publish libffi "$OUT" libffi.a || warn "failed to publish libffi cache entry"
  fi
  export LWJGL_SUNOS_LIBFFI_A
  log "libffi: $LWJGL_SUNOS_LIBFFI_A"
}

# ------------------------------------------------------------------- GLFW
# libglfw.so.  One patched GLFW serves every Minecraft version: GLFW keeps its
# C ABI stable and LWJGL only dlsym()s what it needs.  Pin GLFW_REF per
# version in version.env if you ever need an exact match.
comp_glfw() {
  need git "$CMAKE" "$MAKE" "$CC"
  _src=$WORK/src/glfw
  prepare glfw "$GLFW_URL" "$GLFW_REF" "$_src" "$PATCHES/glfw"
  [ -z "${PREPARE_ONLY:-}" ] || { log "glfw prepared at $_src"; return 0; }
  cache_identity glfw "$_src" "$PATCHES/glfw" "GLFW_X11_WAYLAND_OFF;GLFW_BUILD_X11=ON;CMAKE_SHARED_LINKER_FLAGS=$LDFLAGS;GLFW_CMAKE_ARGS=${GLFW_CMAKE_ARGS:-}"
  cache_restore glfw libglfw.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  # GLFW_BUILD_WAYLAND (>=3.4) and GLFW_USE_WAYLAND (3.3.x) are both forced
  # off; Wayland does not exist on Solaris.
  cmake_build glfw "$_src" \
    -DBUILD_SHARED_LIBS=ON \
    -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF \
    -DGLFW_BUILD_WAYLAND=OFF -DGLFW_USE_WAYLAND=OFF \
    -DGLFW_BUILD_X11=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    $GLFW_CMAKE_ARGS
  stage_lib "$BUILD_DIR" 'libglfw.so*' libglfw.so
  cache_publish glfw "$OUT" libglfw.so || warn "failed to publish GLFW cache entry"
}

# ------------------------------------------------------------------ LWJGL
# liblwjgl.so, liblwjgl_opengl.so, liblwjgl_stb.so and, depending on the
# release, liblwjgl_tinyfd.so / liblwjgl_vma.so (all sources are bundled in the
# LWJGL tree; version.env's NATIVES lists what Minecraft needs), plus a rebuilt
# core jar carrying the SUNOS Platform enum.
comp_lwjgl3() {
  need git ant "$CC"
  [ -n "${JAVA_HOME:-}" ] || die "JAVA_HOME must point at a SPARCV9 JDK (needs include/jni.h)"
  is_dry || [ -f "$JAVA_HOME/include/jni.h" ] || die "no $JAVA_HOME/include/jni.h"
  _src=$WORK/src/lwjgl3
  prepare lwjgl3 "$LWJGL_URL" "$LWJGL_REF" "$_src" "$PATCHES/lwjgl3"
  [ -z "${PREPARE_ONLY:-}" ] || { log "lwjgl3 prepared at $_src"; return 0; }

  lwjgl_preflight "$_src"
  _lwjgl_outputs=
  for _n in $NATIVES; do
    case "$_n" in liblwjgl*.so) _lwjgl_outputs="$_lwjgl_outputs $_n" ;; esac
  done
  [ -n "$_lwjgl_outputs" ] || die "NATIVES contains no LWJGL shared libraries for $MC_VERSION"
  is_dry || [ -f "$LWJGL_SUNOS_LIBFFI_A" ] || die "LWJGL libffi archive is missing: $LWJGL_SUNOS_LIBFFI_A"
  if is_dry; then _ffi_identity=dry-run; else
    _ffi_identity=$(cksum "$LWJGL_SUNOS_LIBFFI_A" 2>/dev/null) || die "cannot identify libffi archive"
  fi
  _java_version=$($JAVA_HOME/bin/java -version 2>&1 | head -1 || printf unknown)
  _ant_version=$(ant -version 2>&1 | head -1 || printf unknown)
  cache_identity lwjgl3 "$_src" "$PATCHES/lwjgl3" "targets=${LWJGL_ANT_TARGETS:-compile-templates generate compile compile-native};args=$LWJGL_ANT_ARGS;static_runtime=$LWJGL_SUNOS_STATIC_RUNTIME;ffi=$_ffi_identity;java=$JAVA_HOME:$_java_version;ant=$_ant_version;outputs=$_lwjgl_outputs"
  cache_restore lwjgl3 $_lwjgl_outputs lwjgl.jar
  [ "$CACHE_HIT" -eq 1 ] && return 0

  # Never let stale output files satisfy the complete-group check after a
  # failed or partial Ant invocation.
  if ! is_dry; then
    rm -f "$OUT/lwjgl.jar"
    for _n in $_lwjgl_outputs; do rm -f "$OUT/$_n"; done
  fi

  # LWJGL keeps template compilation separate from generation.  Generate first
  # fails unless compile-templates has already run; override if needed for a
  # different LWJGL target layout.
  _targets=${LWJGL_ANT_TARGETS:-compile-templates generate compile compile-native}
  # -k: keep going so one failing optional binding does not hide the ones
  # Minecraft needs; verify_natives is the real pass/fail gate.
  if ( cd "$_src" 2>/dev/null || is_dry
       run env CC="$CC" CXX="$CXX" CFLAGS="$ARCH_FLAGS $CFLAGS" \
         CXXFLAGS="$ARCH_FLAGS $CXXFLAGS" LDFLAGS="$ARCH_FLAGS $LDFLAGS" \
         LWJGL_SUNOS_STATIC_RUNTIME="$LWJGL_SUNOS_STATIC_RUNTIME" \
         ant -k $LWJGL_ANT_ARGS $_targets ); then
    _ant_ok=1
  else
    _ant_ok=0
    warn "ant reported errors; checking what was produced"
  fi

  for _n in $NATIVES; do
    case "$_n" in
      liblwjgl*.so) stage_lib "$_src/bin" "$_n" "$_n" ;;
    esac
  done
  lwjgl_core_jar "$_src"
  if [ "$_ant_ok" -eq 1 ] && [ -f "$OUT/lwjgl.jar" ]; then
    _lwjgl_complete=1
    for _n in $_lwjgl_outputs; do
      if [ ! -f "$OUT/$_n" ] || ! elf_check "$OUT/$_n"; then _lwjgl_complete=0; fi
    done
    if [ "$_lwjgl_complete" -eq 1 ]; then
      cache_publish lwjgl3 "$OUT" $_lwjgl_outputs lwjgl.jar || warn "failed to publish LWJGL cache entry"
    else
      warn "LWJGL outputs incomplete or invalid; not caching the component"
    fi
  else
    warn "LWJGL Ant failed; not caching potentially partial outputs"
  fi
}

# lwjgl_preflight SRC -- fail in seconds, not after an hour of compiling.
lwjgl_preflight() {
  is_dry && return 0
  _cfg=$1/config/sunos/build.xml
  if [ ! -f "$_cfg" ]; then
    warn "no config/sunos/build.xml in $1: this LWJGL ref has no SunOS native build."
    warn "The baseline patch targets LWJGL's newer config/<platform> layout; run ./build.sh check."
    die "LWJGL $LWJGL_REF cannot be built for SunOS with the current patches"
  fi
  # the SunOS config demands a static libffi for the target arch
  if [ -z "${LWJGL_SUNOS_LIBFFI_A:-}" ] && [ -f "$WORK/libffi.path" ]; then
    LWJGL_SUNOS_LIBFFI_A=$(cat "$WORK/libffi.path")
  fi
  [ -n "${LWJGL_SUNOS_LIBFFI_A:-}" ] && [ -f "$LWJGL_SUNOS_LIBFFI_A" ] ||
    die "LWJGL_SUNOS_LIBFFI_A not set/valid: run './build.sh $MC_VERSION libffi lwjgl3' or export it"
  export LWJGL_SUNOS_LIBFFI_A
  # every liblwjgl_<mod>.so we must ship needs a <build module="<mod>"> in the SunOS config
  _missing=
  for _n in $NATIVES; do
    case "$_n" in
      liblwjgl.so) ;;
      liblwjgl_*.so)
        _m=${_n#liblwjgl_}; _m=${_m%.so}
        grep -q "module=\"$_m\"" "$_cfg" || _missing="$_missing $_m" ;;
    esac
  done
  if [ -n "$_missing" ] && [ -z "${SKIP_MODULE_CHECK:-}" ]; then
    warn "config/sunos/build.xml builds no native for:$_missing"
    warn "Minecraft $MC_VERSION needs them. Add <build module=...> entries (compare config/linux/build.xml)"
    warn "as a further patch in mc/$MC_VERSION/patches/lwjgl3/, or SKIP_MODULE_CHECK=1 to build anyway."
    die "SunOS LWJGL config is missing modules:$_missing"
  fi
}

# lwjgl_core_jar SRC -- jar the patched core classes (Platform.class lives
# there).  Minecraft keeps the stock jars for every other module.
lwjgl_core_jar() {
  is_dry && { printf '+ jar core classes -> %s/lwjgl.jar\n' "$OUT" >&2; return 0; }
  _cls=
  for _d in "$1/bin/classes/lwjgl/core" "$1/bin/classes/core" "$1/bin/classes/lwjgl"; do
    [ -f "$_d/org/lwjgl/system/Platform.class" ] && { _cls=$_d; break; }
  done
  if [ -z "$_cls" ]; then
    _cls=$(find "$1/bin" -name Platform.class -path '*org/lwjgl/system*' 2>/dev/null | head -1)
    [ -n "$_cls" ] && _cls=${_cls%/org/lwjgl/system/Platform.class}
  fi
  if [ -z "$_cls" ]; then warn "Platform.class not found; lwjgl.jar not produced"; return 0; fi
  _jar=$JAVA_HOME/bin/jar
  [ -x "$_jar" ] || _jar=$(command -v jar 2>/dev/null || true)
  if [ -z "$_jar" ]; then warn "no jar tool; classes are in $_cls"; return 0; fi
  mkdir -p "$OUT"
  ( cd "$_cls" && "$_jar" cf "$OUT/lwjgl.jar" . ) || { warn "jar creation failed"; return 0; }
  log "staged lwjgl.jar from ${_cls#$WORK/}"
}

# --------------------------------------------------------------- jemalloc
# libjemalloc.so.  LWJGL binds the je_-prefixed API; the library is dlopen()ed
# into the JVM, so initial-exec TLS must be off.
comp_jemalloc() {
  need git "$MAKE" "$CC"
  _src=$WORK/src/jemalloc
  prepare jemalloc "$JEMALLOC_URL" "$JEMALLOC_REF" "$_src" "$PATCHES/jemalloc"
  [ -z "${PREPARE_ONLY:-}" ] || { log "jemalloc prepared at $_src"; return 0; }
  cache_identity jemalloc "$_src" "$PATCHES/jemalloc" "prefix=je_;initial-exec-tls=off;background-thread=off;CFLAGS=$CFLAGS;LDFLAGS=$LDFLAGS"
  cache_restore jemalloc libjemalloc.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  ( cd "$_src" 2>/dev/null || is_dry
    # git checkouts ship configure.ac only; release tarballs ship configure.
    if is_dry || [ ! -x ./configure ]; then run autoconf; fi
    # jemalloc 5.3.0 has no --disable-background-thread option. Keep the
    # unfair-lock probe disabled so Solaris does not include os/lock.h, then
    # remove the separate background-thread define after configure; its
    # fallback uses pthread_setaffinity_np/cpuset_t, which Solaris lacks.
    run env CC="$CC" CFLAGS="$ARCH_FLAGS -fPIC $CFLAGS" LDFLAGS="$ARCH_FLAGS $LDFLAGS" \
      je_cv_os_unfair_lock=no \
      ./configure --with-jemalloc-prefix=je_ --disable-initial-exec-tls --disable-cxx
    if is_dry; then :; else
      _defs=include/jemalloc/internal/jemalloc_internal_defs.h
      [ -f "$_defs" ] || die "jemalloc config header not produced: $_src/$_defs"
      sed 's/^#define JEMALLOC_BACKGROUND_THREAD.*/#undef JEMALLOC_BACKGROUND_THREAD/' \
        "$_defs" > "$_defs.tmp" && mv "$_defs.tmp" "$_defs"
    fi
    run "$MAKE" -j "$JOBS" build_lib_shared )
  stage_lib "$_src/lib" 'libjemalloc.so*' libjemalloc.so
  cache_publish jemalloc "$OUT" libjemalloc.so || warn "failed to publish jemalloc cache entry"
}

# -------------------------------------------------------------- OpenAL Soft
comp_openal() {
  need git "$CMAKE" "$MAKE" "$CC"
  _src=$WORK/src/openal
  prepare openal "$OPENAL_URL" "$OPENAL_REF" "$_src" "$PATCHES/openal"
  [ -z "${PREPARE_ONLY:-}" ] || { log "openal prepared at $_src"; return 0; }
  # Use the shared GCC runtime by default; static libgcc/libstdc++ is an
  # opt-in for hosts that provide matching SPARC64 archives. Backend list can
  # be overridden via OPENAL_CMAKE_ARGS (e.g. enable PulseAudio when installed).
  cache_identity openal "$_src" "$PATCHES/openal" "LIBTYPE=SHARED;ALSOFT_UTILS=OFF;ALSOFT_EXAMPLES=OFF;ALSOFT_TESTS=OFF;ALSOFT_INSTALL=OFF;SOLARIS=ON;OSS=ON;runtime=$LWJGL_SUNOS_STATIC_RUNTIME;args=$OPENAL_CMAKE_ARGS"
  cache_restore openal libopenal.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  _openal_runtime_flags=$LDFLAGS
  case "$LWJGL_SUNOS_STATIC_RUNTIME" in
    1|true|TRUE|yes|YES) _openal_runtime_flags="-static-libgcc -static-libstdc++ $LDFLAGS" ;;
  esac
  cmake_build openal "$_src" \
    -DLIBTYPE=SHARED \
    -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
    -DALSOFT_INSTALL=OFF -DALSOFT_NO_CONFIG_UTIL=ON \
    -DALSOFT_RTKIT=OFF -DALSOFT_REQUIRE_RTKIT=OFF \
    -DALSOFT_BACKEND_SOLARIS=ON -DALSOFT_BACKEND_OSS=ON \
    -DALSOFT_BACKEND_ALSA=OFF -DALSOFT_BACKEND_PORTAUDIO=OFF \
    -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_SNDIO=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,gnu-version-script-compat $_openal_runtime_flags" \
    $OPENAL_CMAKE_ARGS
  stage_lib "$BUILD_DIR" 'libopenal.so*' libopenal.so
  cache_publish openal "$OUT" libopenal.so || warn "failed to publish OpenAL cache entry"
}

# --------------------------------------------------------------------- SDL3
# libSDL3.so with Vulkan enabled on Solaris (needs the sdl3 patch set).
comp_sdl3() {
  [ -n "${SDL3_REF:-}" ] || die "Minecraft $MC_VERSION has no SDL3 entry in mc/$MC_VERSION/version.env"
  need git "$CMAKE" "$MAKE" "$CC"
  _src=$WORK/src/sdl3
  prepare sdl3 "$SDL3_URL" "$SDL3_REF" "$_src" "$PATCHES/sdl3"
  [ -z "${PREPARE_ONLY:-}" ] || { log "sdl3 prepared at $_src"; return 0; }
  cache_identity sdl3 "$_src" "$PATCHES/sdl3" "SDL_SHARED=ON;SDL_STATIC=OFF;SDL_X11=ON;SDL_WAYLAND=OFF;SDL_VULKAN=ON;DBUS=OFF;CMAKE_SHARED_LINKER_FLAGS=$LDFLAGS;args=$SDL3_CMAKE_ARGS"
  cache_restore sdl3 libSDL3.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  cmake_build sdl3 "$_src" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL=OFF -DSDL_X11=ON -DSDL_WAYLAND=OFF -DSDL_VULKAN=ON \
    -DSDL_DBUS=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    $SDL3_CMAKE_ARGS
  stage_lib "$BUILD_DIR" 'libSDL3.so*' libSDL3.so
  cache_publish sdl3 "$OUT" libSDL3.so || warn "failed to publish SDL3 cache entry"
}

# --------------------------------------------------------------- FreeType
# libfreetype.so (Minecraft >= 1.21).  LWJGL only binds the core FT_ API, so
# every optional dependency (zlib, bzip2, png, brotli, harfbuzz) stays off.
comp_freetype() {
  [ -n "${FREETYPE_REF:-}" ] || die "Minecraft $MC_VERSION has no FreeType entry in mc/$MC_VERSION/version.env"
  need git "$CMAKE" "$MAKE" "$CC"
  _src=$WORK/src/freetype
  prepare freetype "$FREETYPE_URL" "$FREETYPE_REF" "$_src" "$PATCHES/freetype"
  [ -z "${PREPARE_ONLY:-}" ] || { log "freetype prepared at $_src"; return 0; }
  cache_identity freetype "$_src" "$PATCHES/freetype" "FT_DISABLE_ZLIB=ON;FT_DISABLE_BZIP2=ON;FT_DISABLE_PNG=ON;FT_DISABLE_HARFBUZZ=ON;FT_DISABLE_BROTLI=ON;FT_CONFIG_OPTION_ERROR_STRINGS;CFLAGS=$ARCH_FLAGS $CFLAGS;LDFLAGS=$LDFLAGS"
  cache_restore freetype libfreetype.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  cmake_build freetype "$_src" \
    -DBUILD_SHARED_LIBS=ON \
    -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
    -DCMAKE_C_FLAGS="$ARCH_FLAGS $CFLAGS -DFT_CONFIG_OPTION_ERROR_STRINGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS"
  stage_lib "$BUILD_DIR" 'libfreetype.so*' libfreetype.so
  cache_publish freetype "$OUT" libfreetype.so || warn "failed to publish FreeType cache entry"
}

# ---------------------------------------------------------------- Shaderc
# libshaderc.so (Minecraft >= 26.2).  LWJGL's fork folds glslang, SPIRV and
# SPIRV-Tools into libshaderc_shared.so; the stock google/shaderc does not
# export those APIs.  shaderc fetches glslang/SPIRV-Tools/SPIRV-Headers with
# utils/git-sync-deps, which needs network access (SHADERC_SKIP_SYNC=1 if the
# third_party checkouts are already provided via a patch or a pre-made tree).
comp_shaderc() {
  [ -n "${SHADERC_REF:-}" ] || die "Minecraft $MC_VERSION has no Shaderc entry in mc/$MC_VERSION/version.env"
  need git python3 "$CMAKE" "$MAKE" "$CC" "$CXX"
  _src=$WORK/src/shaderc
  prepare shaderc "$SHADERC_URL" "$SHADERC_REF" "$_src" "$PATCHES/shaderc"
  [ -z "${PREPARE_ONLY:-}" ] || { log "shaderc prepared at $_src"; return 0; }
  _shaderc_deps=
  _shaderc_unknown=0
  for _dep in glslang SPIRV-Tools SPIRV-Headers; do
    if [ ! -d "$_src/third_party/$_dep" ]; then
      _shaderc_deps="$_shaderc_deps;$_dep=missing"
      _shaderc_unknown=1
      continue
    fi
    _dep_commit=$(git -C "$_src/third_party/$_dep" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$_dep_commit" ]; then
      _dep_state=$(git -C "$_src/third_party/$_dep" status --porcelain 2>/dev/null || printf unknown)
      [ -z "$_dep_state" ] || _shaderc_unknown=1
      _shaderc_deps="$_shaderc_deps;$_dep=$_dep_commit;state=$_dep_state"
    else
      _shaderc_deps="$_shaderc_deps;$_dep=unversioned"
      _shaderc_unknown=1
    fi
  done
  cache_identity shaderc "$_src" "$PATCHES/shaderc" "skip_sync=${SHADERC_SKIP_SYNC:-};deps=$_shaderc_deps;shared_linker_flags=$LDFLAGS;args=$SHADERC_CMAKE_ARGS"
  [ "$_shaderc_unknown" -eq 0 ] || CACHE_SAFE=0
  cache_restore shaderc libshaderc.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  if [ -z "${SHADERC_SKIP_SYNC:-}" ]; then
    ( cd "$_src" 2>/dev/null || is_dry
      run python3 utils/git-sync-deps )
    # Synced third-party sources are new effective inputs; recompute identity.
    _shaderc_deps=
    _shaderc_unknown=0
    for _dep in glslang SPIRV-Tools SPIRV-Headers; do
      if [ ! -d "$_src/third_party/$_dep" ]; then _shaderc_unknown=1; _shaderc_deps="$_shaderc_deps;$_dep=missing"; continue; fi
      _dep_commit=$(git -C "$_src/third_party/$_dep" rev-parse HEAD 2>/dev/null || true)
      if [ -z "$_dep_commit" ]; then _shaderc_unknown=1; _shaderc_deps="$_shaderc_deps;$_dep=unversioned"; continue; fi
      _dep_state=$(git -C "$_src/third_party/$_dep" status --porcelain 2>/dev/null || printf unknown)
      [ -z "$_dep_state" ] || _shaderc_unknown=1
      _shaderc_deps="$_shaderc_deps;$_dep=$_dep_commit;state=$_dep_state"
    done
    cache_identity shaderc "$_src" "$PATCHES/shaderc" "skip_sync=${SHADERC_SKIP_SYNC:-};deps=$_shaderc_deps;shared_linker_flags=$LDFLAGS;args=$SHADERC_CMAKE_ARGS"
    [ "$_shaderc_unknown" -eq 0 ] || CACHE_SAFE=0
  fi
  cmake_build shaderc "$_src" \
    -DSHADERC_SKIP_INSTALL=ON -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    $SHADERC_CMAKE_ARGS
  stage_lib "$BUILD_DIR" 'libshaderc_shared.so*' libshaderc.so
  cache_publish shaderc "$OUT" libshaderc.so || warn "failed to publish Shaderc cache entry"
}

# ------------------------------------------------------------ SPIRV-Cross
# libspirv-cross.so: the C API (spirv_cross_c.h) as a shared library, used by
# LWJGL's "spvc" binding (Minecraft >= 26.2).
comp_spvc() {
  [ -n "${SPVC_REF:-}" ] || die "Minecraft $MC_VERSION has no SPIRV-Cross entry in mc/$MC_VERSION/version.env"
  need git "$CMAKE" "$MAKE" "$CC" "$CXX"
  _src=$WORK/src/spvc
  prepare spvc "$SPVC_URL" "$SPVC_REF" "$_src" "$PATCHES/spvc"
  [ -z "${PREPARE_ONLY:-}" ] || { log "spvc prepared at $_src"; return 0; }
  cache_identity spvc "$_src" "$PATCHES/spvc" "STATIC=OFF;SHARED=ON;CLI=OFF;FORCE_PIC=ON;shared_linker_flags=$LDFLAGS;args=$SPVC_CMAKE_ARGS"
  cache_restore spvc libspirv-cross.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  cmake_build spvc "$_src" \
    -DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SKIP_INSTALL=ON \
    -DSPIRV_CROSS_WERROR=OFF -DSPIRV_CROSS_FORCE_PIC=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    $SPVC_CMAKE_ARGS
  stage_lib "$BUILD_DIR" 'libspirv-cross-c-shared.so*' libspirv-cross.so
  cache_publish spvc "$OUT" libspirv-cross.so || warn "failed to publish SPIRV-Cross cache entry"
}
