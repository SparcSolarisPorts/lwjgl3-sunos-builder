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
  # Keep the optional argument list defined for Solaris /usr/xpg4/bin/sh,
  # where set -u makes an unset expansion fatal.
  : "${GLFW_CMAKE_ARGS:=}"
  need git "$CMAKE" "$MAKE" "$CC"
  _src=$WORK/src/glfw
  prepare glfw "$GLFW_URL" "$GLFW_REF" "$_src" "$PATCHES/glfw"
  [ -z "${PREPARE_ONLY:-}" ] || { log "glfw prepared at $_src"; return 0; }
  cache_identity glfw "$_src" "$PATCHES/glfw" "GLFW_X11_WAYLAND_OFF;GLFW_BUILD_X11=ON;CMAKE_SHARED_LINKER_FLAGS=$LDFLAGS;GLFW_CMAKE_ARGS=${GLFW_CMAKE_ARGS:-}"
  cache_restore glfw libglfw.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
  # Wayland does not exist on Solaris. GLFW 3.5 rejects the removed
  # GLFW_USE_WAYLAND cache variable, so only use the supported build toggle.
  cmake_build glfw "$_src" \
    -DBUILD_SHARED_LIBS=ON \
    -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF \
    -DGLFW_BUILD_WAYLAND=OFF \
    -DGLFW_BUILD_X11=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    $GLFW_CMAKE_ARGS
  stage_lib "$BUILD_DIR" 'libglfw.so*' libglfw.so
  cache_publish glfw "$OUT" libglfw.so || warn "failed to publish GLFW cache entry"
}

# lwjgl_patch_nashorn SRC -- replace the <script language="javascript"> block
# in build-bindings.xml with pure Ant XML so the build works on JDK 17+
# where Nashorn was removed.  LWJGL 3.1.x–3.2.x use Nashorn for the
# 'bindings' target; LWJGL 3.3+ switched to Kotlin and don't need this.
lwjgl_patch_nashorn() {
  is_dry && return 0
  _src=$1
  _bindings=$_src/config/build-bindings.xml
  [ -f "$_bindings" ] || return 0
  # Only patch if the file contains a Nashorn script
  grep -q 'script language="javascript"' "$_bindings" || return 0
  # Already patched
  grep -q 'Replaced Nashorn script' "$_bindings" && return 0
  log "patching build-bindings.xml to remove Nashorn dependency"

  # Extract enabled binding modules (excluding DISABLE_CHECKS)
  _mods=$(grep 'name="binding\.' "$_bindings" | grep 'value="true"' | \
    sed 's/.*name="binding\.\([^"]*\)".*/\1/' | tr '\n' ',')
  # Strip trailing comma
  _mods=${_mods%,}

  # Extract java-only bindings
  _mod_java_only=$(grep 'name="java-only\.binding\.' "$_bindings" | grep 'value="true"' | \
    sed 's/.*name="java-only\.binding\.\([^"]*\)".*/\1/' | tr '\n' ',')
  _mod_java_only=${_mod_java_only%,}
  : "${_mod_java_only:=}"

  # Build module list (core + all bindings)
  _mod_list="core"
  if [ -n "$_mods" ]; then _mod_list="$_mod_list,$_mods"; fi

  # Build generator bindings string
  _gen_bindings="-Dbinding.DISABLE_CHECKS=\${binding.DISABLE_CHECKS}"
  for _m in $(printf '%s' "$_mods" | tr ',' ' '); do
    _gen_bindings="$_gen_bindings -Dbinding.$_m=true"
  done

  # Build classpath, templatepath, sourcepath
  # LWJGL 3.1.x uses src/main/kotlin for templates; 3.2.x+ uses src/templates/kotlin
  _tmpl_base="src/main/kotlin"
  case "$LWJGL_VERSION" in
    3.2.*|3.3.*|3.4.*) _tmpl_base="src/templates/kotlin" ;;
  esac
  _mod_classpath="bin/classes/lwjgl/core"
  _mod_templatepath="modules/lwjgl/core/$_tmpl_base"
  _mod_sourcepath="modules/lwjgl/core/src/generated/java"
  for _m in $(printf '%s' "$_mods" | tr ',' ' '); do
    _mod_classpath="$_mod_classpath:bin/classes/lwjgl/$_m"
    _mod_templatepath="$_mod_templatepath:modules/lwjgl/$_m/$_tmpl_base"
    _mod_sourcepath="$_mod_sourcepath:modules/lwjgl/$_m/src/generated/java"
  done

  # Write the replacement XML to a temp file (awk -v can't handle multiline)
  _repl_file=$(mktemp)
  printf '%s\n' \
    "        <!-- Replaced Nashorn script with pure Ant XML for JDK 17+ compatibility -->" \
    "        <property name=\"generator.bindings\" value=\"$_gen_bindings\"/>" \
    "        <property name=\"module.list\" value=\"$_mod_list\"/>" \
    "        <property name=\"module.list.java-only\" value=\"$_mod_java_only\"/>" \
    "        <property name=\"module.classpath\" value=\"$_mod_classpath\"/>" \
    "        <property name=\"module.templatepath\" value=\"$_mod_templatepath\"/>" \
    "        <property name=\"module.sourcepath\" value=\"$_mod_sourcepath\"/>" \
    > "$_repl_file"

  # Use awk to replace the script block, reading replacement from file
  awk -v repl_file="$_repl_file" '
    /<script language="javascript">/ {
      in_script=1
      while ((getline line < repl_file) > 0) print line
      close(repl_file)
      next
    }
    /<\/script>/ && in_script { in_script=0; next }
    in_script { next }
    { print }
  ' "$_bindings" > "$_bindings.tmp"
  rm -f "$_repl_file"
  mv "$_bindings.tmp" "$_bindings"
  log "Nashorn script replaced in build-bindings.xml"
}

# lwjgl_patch_kotlinc SRC -- fix Kotlin compiler version in update-dependencies.xml
# Kotlin compiler crashes on SPARC Solaris with JDK 17 for 1.x ("Unbalanced
# tree").  LWJGL 3.3.x (Kotlin 1.x) is downgraded to 1.9.23.
# LWJGL 3.4.x+ (Kotlin 2.x) is left unchanged — it works with JDK 25.
lwjgl_patch_kotlinc() {
  is_dry && return 0
  _src=$1
  _upd=$_src/update-dependencies.xml
  [ -f "$_upd" ] || return 0
  grep -q 'kotlinc-version' "$_upd" || return 0
  # Patch Kotlin 1.x only (LWJGL 3.3.x) — Kotlin 2.x (LWJGL 3.4.x+) is left as-is
  if grep -q 'kotlinc-version" value="1\.' "$_upd"; then
    log "patching update-dependencies.xml: Kotlin 1.x -> 1.9.23 (SPARC compatibility)"
    sed 's/kotlinc-version" value="1\.[^"]*"/kotlinc-version" value="1.9.23"/; s/kotlinc-build" value="1\.[^"]*"/kotlinc-build" value="1.9.23-release-471"/' "$_upd" > "$_upd.tmp"
    mv "$_upd.tmp" "$_upd"
  fi
  # Do NOT patch Kotlin 2.x (LWJGL 3.4.x+) — it works with JDK 25
}

# lwjgl_prepopulate_libs SRC -- copy cached Java/Kotlin dependencies into
# LWJGL's bin/libs/ so the Ant build can run offline.  Older LWJGL tags
# (3.1.x–3.2.x) download from http://central.maven.org, which is often
# unreachable; newer tags also benefit from skipping network I/O.
lwjgl_prepopulate_libs() {
  is_dry && return 0
  _src=$1
  _root_dir=$(CDPATH= cd "$_src/../../../.." && pwd)
  _deps_root=$_root_dir/tools/lwjgl-deps
  [ -d "$_deps_root" ] || return 0
  _lib_dir=$_src/bin/libs
  _java_dir=$_lib_dir/java
  _kotlinc_dir=$_lib_dir/kotlinc

  # Copy Java dependencies (jsr305, jcommander, testng, joml)
  if [ -d "$_deps_root/java" ]; then
    mkdir -p "$_java_dir"
    for _jar in "$_deps_root/java/"*.jar; do
      [ -f "$_jar" ] || continue
      cp -f "$_jar" "$_java_dir/" 2>/dev/null || true
    done
  fi

  # Copy Kotlin compiler matching the LWJGL version (only for 3.1.x-3.2.x that
  # can't download from Maven Central).  LWJGL 3.3+ downloads kotlinc itself.
  if [ ! -d "$_kotlinc_dir" ] && [ -d "$_deps_root/kotlin" ]; then
    _lw_kver=
    case "$LWJGL_VERSION" in
      3.1.*) _lw_kver="1.2.20" ;;
      3.2.*) _lw_kver="1.3.11" ;;
    esac
    if [ -n "$_lw_kver" ] && [ -d "$_deps_root/kotlin/$_lw_kver" ]; then
      cp -r "$_deps_root/kotlin/$_lw_kver" "$_kotlinc_dir" 2>/dev/null || true
    fi
  fi

  # Create touch.txt so update-dependencies.xml thinks libs are up to date
  touch "$_java_dir/touch.txt" 2>/dev/null || true

  # LWJGL 3.2.x build.xml references src/main/kotlin for all modules, but many
  # don't have Kotlin sources. Create empty directories so kotlinc doesn't fail.
  if [ -d "$_src/modules/lwjgl" ]; then
    for _mod in "$_src/modules/lwjgl"/*/; do
      [ -d "$_mod" ] || continue
      mkdir -p "$_mod/src/main/kotlin" 2>/dev/null || true
    done
  fi

  log "LWJGL dependencies pre-populated from $_deps_root"
}

# ------------------------------------------------------------------ LWJGL
# liblwjgl.so, liblwjgl_opengl.so, liblwjgl_stb.so and, depending on the
# release, liblwjgl_tinyfd.so / liblwjgl_vma.so (all sources are bundled in the
# LWJGL tree; version.env's NATIVES lists what Minecraft needs), plus a rebuilt
# override jar carrying patched core and binding Java classes.
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
  cache_identity lwjgl3 "$_src" "$PATCHES/lwjgl3" "targets=${LWJGL_ANT_TARGETS:-compile-templates generate compile compile-native};args=$LWJGL_ANT_ARGS;static_runtime=$LWJGL_SUNOS_STATIC_RUNTIME;ffi=$_ffi_identity;java=$JAVA_HOME:$_java_version;ant=$_ant_version;binding_class_staging=v2:ALC,GL,GLES,VK;outputs=$_lwjgl_outputs"
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

  # Replace Nashorn <script> block with pure Ant XML for JDK 17+ compatibility
  lwjgl_patch_nashorn "$_src"
  # Fix Kotlin compiler version for LWJGL 3.3.x+ (crashes on SPARC)
  # Must run BEFORE lwjgl_prepopulate_libs so the cached kotlinc is removed
  # before the pre-populated libs are copied.
  lwjgl_patch_kotlinc "$_src"
  # Pre-populate LWJGL bin/libs/ from cached dependencies so the Ant build
  # does not try to download from Maven Central (which may be unreachable).
  # Older LWJGL tags (3.1.x–3.2.x) use http://central.maven.org which is
  # often unreachable; newer tags also benefit from offline builds.
  lwjgl_prepopulate_libs "$_src"

  # -k: keep going so one failing optional binding does not hide the ones
  # Minecraft needs; verify_natives is the real pass/fail gate.
  # -Dbuild.offline=true: only for LWJGL 3.1.x-3.2.x that use the dead
  # http://central.maven.org; LWJGL 3.3+ uses https://repo1.maven.org and
  # can download kotlinc normally.
  _offline_flag=""
  case "$LWJGL_VERSION" in
    3.1.*|3.2.*) _offline_flag="-Dbuild.offline=true" ;;
  esac
  if ( cd "$_src" 2>/dev/null || is_dry
       run env CC="$CC" CXX="$CXX" CFLAGS="$ARCH_FLAGS $CFLAGS" \
         CXXFLAGS="$ARCH_FLAGS $CXXFLAGS" LDFLAGS="$ARCH_FLAGS $LDFLAGS" \
         LWJGL_SUNOS_STATIC_RUNTIME="$LWJGL_SUNOS_STATIC_RUNTIME" \
         ant -k $_offline_flag $LWJGL_ANT_ARGS $_targets ); then
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
  lwjgl_module_jars "$_src"
  _lwjgl_complete=0
  if [ -f "$OUT/lwjgl.jar" ]; then
    _lwjgl_complete=1
    for _n in $_lwjgl_outputs; do
      if [ ! -f "$OUT/$_n" ] || ! elf_check "$OUT/$_n"; then _lwjgl_complete=0; break; fi
    done
  fi
  if [ "$_lwjgl_complete" -eq 1 ]; then
    cache_publish lwjgl3 "$OUT" $_lwjgl_outputs lwjgl.jar || warn "failed to publish LWJGL cache entry"
  else
    if [ "$_ant_ok" -ne 1 ]; then
      warn "LWJGL Ant failed; not caching potentially partial outputs"
    else
      warn "LWJGL outputs incomplete or invalid; not caching the component"
    fi
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

# lwjgl_find_class_root SRC MODULE CLASS -- resolve a compiled class root.
# The Ant layouts used by the supported LWJGL tags put each module below
# bin/classes/lwjgl/<module>; the following fallbacks preserve older layouts.
lwjgl_find_class_root() {
  _src=$1; _module=$2; _class=$3; _root=
  for _d in "$_src/bin/classes/lwjgl/$_module" "$_src/bin/classes/$_module" \
            "$_src/bin/classes/lwjgl"; do
    [ -f "$_d/$_class" ] && { _root=$_d; break; }
  done
  if [ -z "$_root" ]; then
    _match=$(find "$_src/bin/classes" -type f -path "*/$_class" 2>/dev/null | sort | head -1)
    [ -n "$_match" ] && _root=${_match%/$_class}
  fi
  [ -n "$_root" ] && printf '%s\n' "$_root"
}

# lwjgl_stage_class_family JAR ROOT CLASS -- add a patched class and any
# nested/synthetic companions from the same output root.  Companions are
# optional because javac output varies, but must never come from another root.
lwjgl_stage_class_family() {
  _jar=$1; _root=$2; _class=$3; _primary=$_root/$_class
  [ -f "$_primary" ] || die "patched LWJGL class missing: $_primary"
  _dir=${_class%/*}; _name=${_class##*/}; _stem=${_name%.class}
  _files=$_class
  for _companion in "$_root/$_dir/$_stem"'$'*.class; do
    [ -f "$_companion" ] || continue
    _files="$_files ${_companion#$_root/}"
  done
  # Solaris jar applies -C only to the next file operand. Update each class
  # separately so companions are resolved from the selected output root too.
  for _file in $_files; do
    ( "$_jar" uf "$OUT/lwjgl.jar" -C "$_root" "$_file" ) ||
      die "could not add patched LWJGL class $_file to $OUT/lwjgl.jar"
  done
  log "staged patched $_class family from ${_root#$WORK/}"
}

# lwjgl_core_jar SRC -- jar patched core classes and the patched binding
# classes. Minecraft keeps stock module jars, so this jar must override every
# binding changed by the Solaris patch, including javac-generated VK$1.class.
lwjgl_core_jar() {
  is_dry && { printf '+ jar patched LWJGL classes -> %s/lwjgl.jar\n' "$OUT" >&2; return 0; }
  _src=$1
  _cls=$(lwjgl_find_class_root "$_src" core org/lwjgl/system/Platform.class)
  if [ -z "$_cls" ]; then die "Platform.class not found in LWJGL build output"; fi
  _jar=$JAVA_HOME/bin/jar
  [ -x "$_jar" ] || _jar=$(command -v jar 2>/dev/null || true)
  [ -n "$_jar" ] || die "no jar tool found; cannot create $OUT/lwjgl.jar"
  mkdir -p "$OUT"
  "$_jar" cf "$OUT/lwjgl.jar" -C "$_cls" . || die "jar creation failed: $OUT/lwjgl.jar"

  for _binding in openal:ALC opengl:GL opengles:GLES vulkan:VK; do
    _module=${_binding%%:*}; _name=${_binding#*:}
    _root=$(lwjgl_find_class_root "$_src" "$_module" "org/lwjgl/$_module/$_name.class")
    [ -n "$_root" ] || die "patched LWJGL class not found: org/lwjgl/$_module/$_name.class"
    lwjgl_stage_class_family "$_jar" "$_root" "org/lwjgl/$_module/$_name.class"
  done
  log "staged lwjgl.jar from ${_cls#$WORK/}"
}

# lwjgl_module_jars SRC -- copy all compiled LWJGL module JARs from the build
# output into $OUT/lwjgl/ so they are available alongside lwjgl.jar.  The Ant
# build places compiled .class files under bin/classes/lwjgl/<module>/; this
# function jars each module and copies the result.
lwjgl_module_jars() {
  is_dry && { printf '+ jar LWJGL modules -> %s/lwjgl/\n' "$OUT" >&2; return 0; }
  _src=$1
  _classes=$_src/bin/classes/lwjgl
  [ -d "$_classes" ] || { warn "no LWJGL module classes at $_classes"; return 0; }
  _jar=$JAVA_HOME/bin/jar
  [ -x "$_jar" ] || _jar=$(command -v jar 2>/dev/null || true)
  [ -n "$_jar" ] || return 0
  _out_lwjgl=$OUT/lwjgl
  _out_version=$_out_lwjgl/$LWJGL_VERSION
  mkdir -p "$_out_version"
  _count=0
  for _mod_dir in "$_classes"/*/; do
    [ -d "$_mod_dir" ] || continue
    _mod=$(basename "$_mod_dir")
    # Skip non-module directories
    case "$_mod" in core|openal|opengl|opengles|vulkan|glfw|jemalloc|freetype|shaderc|spvc|stb|tinyfd|vma|sdl|assimp|bgfx|egl|fmod|harfbuzz|hwloc|jawt|ktx|llvm|lmdb|lz4|meshoptimizer|msdfgen|nanovg|nfd|nuklear|odbc|opencl|openxr|opus|par|remotery|renderdoc|rpmalloc|spng|tinyexr|xxhash|yoga|zstd|core11|core17|core25) ;;
      *) continue ;;
    esac
    _mod_name=$_mod
    [ "$_mod_name" = "core" ] && _mod_name="lwjgl"
    [ "$_mod_name" != "lwjgl" ] && _mod_name="lwjgl-$_mod_name"
    _dest_jar=$_out_version/${_mod_name}.jar
    # Skip if already exists (e.g. from a previous run)
    [ -f "$_dest_jar" ] && continue
    "$_jar" cf "$_dest_jar" -C "$_mod_dir" . 2>/dev/null || continue
    _count=$((_count + 1))
  done
  [ "$_count" -gt 0 ] && log "staged $_count LWJGL module JARs into $_out_version/"
}

# --------------------------------------------------------------- jemalloc
# libjemalloc.so.  LWJGL binds the je_-prefixed API; the library is dlopen()ed
# into the JVM, so initial-exec TLS must be off.
comp_jemalloc() {
  need git "$MAKE" "$CC"
  _src=$WORK/src/jemalloc
  prepare jemalloc "$JEMALLOC_URL" "$JEMALLOC_REF" "$_src" "$PATCHES/jemalloc"
  [ -z "${PREPARE_ONLY:-}" ] || { log "jemalloc prepared at $_src"; return 0; }
  case "$LWJGL_VERSION" in
    3.4.3*) JEMALLOC_REQUIRED_SYMBOLS='je_free_sized je_free_aligned_sized' ;;
    *) JEMALLOC_REQUIRED_SYMBOLS= ;;
  esac
  cache_identity jemalloc "$_src" "$PATCHES/jemalloc" "prefix=je_;initial-exec-tls=off;background-thread=off;strerror_r=solaris-int;required_symbols=$JEMALLOC_REQUIRED_SYMBOLS;CFLAGS=$CFLAGS;LDFLAGS=$LDFLAGS"
  cache_restore jemalloc libjemalloc.so
  if [ "$CACHE_HIT" -eq 1 ]; then
    jemalloc_symbols_check "$OUT/libjemalloc.so" || die "cached jemalloc lacks LWJGL sized-free symbols; rebuild jemalloc"
    return 0
  fi
  ( cd "$_src" 2>/dev/null || is_dry
    # git checkouts ship configure.ac only; release tarballs ship configure.
    if is_dry || [ ! -x ./configure ]; then run autoconf; fi
    # jemalloc 5.3.0 has no --disable-background-thread option. Keep the
    # unfair-lock probe disabled so Solaris does not include os/lock.h, then
    # remove the separate background-thread define after configure; its
    # fallback uses pthread_setaffinity_np/cpuset_t, which Solaris lacks.
    run env CC="$CC" CFLAGS="$ARCH_FLAGS -fPIC $CFLAGS" LDFLAGS="$ARCH_FLAGS $LDFLAGS" \
      je_cv_os_unfair_lock=no \
      je_cv_strerror_r_returns_char_with_gnu_source=no \
      je_cv_strerror_r_header_pass=yes \
      ./configure --with-jemalloc-prefix=je_ --disable-initial-exec-tls --disable-cxx
    if is_dry; then :; else
      _defs=include/jemalloc/internal/jemalloc_internal_defs.h
      [ -f "$_defs" ] || die "jemalloc config header not produced: $_src/$_defs"
      sed 's/^#define JEMALLOC_BACKGROUND_THREAD.*/#undef JEMALLOC_BACKGROUND_THREAD/' \
        "$_defs" > "$_defs.tmp" && mv "$_defs.tmp" "$_defs"
    fi
    run "$MAKE" -j "$JOBS" build_lib_shared )
  stage_lib "$_src/lib" 'libjemalloc.so*' libjemalloc.so
  jemalloc_symbols_check "$OUT/libjemalloc.so" || die "built jemalloc lacks LWJGL sized-free symbols; need je_free_sized and je_free_aligned_sized"
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
  if [ -z "${SHADERC_SKIP_SYNC:-}" ]; then
    ( cd "$_src" 2>/dev/null || is_dry
      run python3 utils/git-sync-deps )
  else
    for _dep in glslang spirv-tools spirv-headers; do
      [ -d "$_src/third_party/$_dep" ] || die "SHADERC_SKIP_SYNC=1 requires $_src/third_party/$_dep"
    done
  fi
  _shaderc_deps=
  _shaderc_unknown=0
  for _dep in glslang spirv-tools spirv-headers; do
    if [ ! -d "$_src/third_party/$_dep" ]; then
      _shaderc_deps="$_shaderc_deps;$_dep=missing"
      _shaderc_unknown=1
      continue
    fi
    _dep_fingerprint=$(cache_dependency_fingerprint "$_src/third_party/$_dep" 2>/dev/null) || {
      _dep_fingerprint=unknown; _shaderc_unknown=1;
    }
    _shaderc_deps="$_shaderc_deps;$_dep=$_dep_fingerprint"
  done
  cache_identity shaderc "$_src" "$PATCHES/shaderc" "skip_sync=${SHADERC_SKIP_SYNC:-};deps=$_shaderc_deps;shared_linker_flags=$LDFLAGS;args=$SHADERC_CMAKE_ARGS" third_party
  [ "$_shaderc_unknown" -eq 0 ] || CACHE_SAFE=0
  cache_restore shaderc libshaderc.so
  [ "$CACHE_HIT" -eq 1 ] && return 0
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
