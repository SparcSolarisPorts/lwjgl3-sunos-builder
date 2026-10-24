#!/usr/xpg4/bin/sh
# mc_main MCDIR [component ...]   -- entry point used by mc/<ver>/build.sh
# (the caller has already sourced lib/common.sh)

mc_main() {
  MCDIR=$1; shift
  ROOT=$(CDPATH= cd "$MCDIR/../.." && pwd)
  . "$MCDIR/version.env"
  . "$ROOT/lib/components.sh"

  PATCHES=$MCDIR/patches
  CACHE=${CACHE:-$ROOT/cache}
  ARTIFACTS=${ARTIFACTS:-$ROOT/build/artifacts}
  WORK=${WORK:-$ROOT/work/$MC_VERSION}
  OUT=${OUT:-$ROOT/bin/$MC_VERSION}

  CC=${CC:-gcc}; CXX=${CXX:-g++}
  CMAKE=${CMAKE:-cmake}
  # Solaris builds require GNU make; do not silently fall back to /usr/bin/make.
  MAKE=${MAKE:-gmake}
  PATCH_CMD=${PATCH_CMD:-$(first_tool gpatch patch)}
  ARCH_FLAGS=${ARCH_FLAGS--m64}
  CFLAGS=${CFLAGS-}; CXXFLAGS=${CXXFLAGS-}; LDFLAGS=${LDFLAGS-}
  LWJGL_SUNOS_STATIC_RUNTIME=${LWJGL_SUNOS_STATIC_RUNTIME-}
  LWJGL_ANT_ARGS=${LWJGL_ANT_ARGS-}
  OPENAL_CMAKE_ARGS=${OPENAL_CMAKE_ARGS-}
  SDL3_CMAKE_ARGS=${SDL3_CMAKE_ARGS-}
  SHADERC_CMAKE_ARGS=${SHADERC_CMAKE_ARGS-}
  SPVC_CMAKE_ARGS=${SPVC_CMAKE_ARGS-}
  if [ -z "${JOBS:-}" ]; then
    JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    case "$JOBS" in ''|*[!0-9]*) JOBS=$(psrinfo 2>/dev/null | wc -l | tr -d ' ') ;; esac
    case "$JOBS" in ''|0|*[!0-9]*) JOBS=4 ;; esac
  fi
  case "$JOBS" in
    ''|*[!0-9]*|0) die "JOBS must be a positive integer (got '$JOBS')" ;;
  esac
  log "using $JOBS build job(s)"

  # --- Automatic JDK selection based on LWJGL version ---
  # Discovers JDKs in /usr/jdk/instances/ and ~/Downloads/jdk-*/
  # Only full JDKs (with include/jni.h) are considered; JREs are skipped.
  # LWJGL 3.1.x-3.2.x (MC 1.13-1.18): JDK 8 preferred (has Nashorn)
  # LWJGL 3.3.x (MC 1.19-1.21): JDK 17 (Kotlin "Unbalanced tree" on JDK 21+)
  # LWJGL 3.4+ (MC 26.3+): JDK 25 preferred, falls back to JDK 17
  _select_jdk() {
    # If JAVA_HOME is explicitly set and has jni.h, check whether it is
    # compatible with this LWJGL version.  Kotlin on SPARC crashes on JDK 21+,
    # so reject JDK 21+ for LWJGL 3.3.x only; LWJGL 3.4+ (MC 26.3+) allows JDK 25.
    if [ -n "${JAVA_HOME:-}" ] && [ -f "${JAVA_HOME:-}/include/jni.h" ]; then
      _explicit_ver=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | sed 's/.*version "\(.*\)".*/\1/' | cut -d'.' -f1)
      _lw_major=$(printf '%s' "$LWJGL_VERSION" | cut -d'.' -f1)
      _lw_minor=$(printf '%s' "$LWJGL_VERSION" | cut -d'.' -f2)
      _reject=0
      if [ "$_lw_major" -eq 3 ] 2>/dev/null; then
        if [ "$_lw_minor" -le 2 ] 2>/dev/null; then
          # LWJGL 3.1.x-3.2.x: need JDK 8 (Nashorn) or JDK 17; reject JDK 21+
          case "$_explicit_ver" in 1|1[1-9]) ;; 2[1-9]|3*) _reject=1 ;; esac
        elif [ "$_lw_minor" -eq 3 ] 2>/dev/null; then
          # LWJGL 3.3.x: reject JDK 21+ (Kotlin "Unbalanced tree" on SPARC)
          case "$_explicit_ver" in 2[1-9]|3*) _reject=1 ;; esac
        else
          # LWJGL 3.4+: allow JDK 25, reject other JDK 21+ (except 25)
          case "$_explicit_ver" in 25) ;; 2[1-9]|3*) _reject=1 ;; esac
        fi
      fi
      if [ "$_reject" -eq 0 ]; then
        return 0
      fi
      warn "JAVA_HOME=$JAVA_HOME (JDK $_explicit_ver) is incompatible with LWJGL $LWJGL_VERSION on SPARC; auto-selecting JDK"
    fi

    # Discover available JDKs (only those with jni.h = full JDK, not JRE)
    _jdk8=
    _jdk17=
    _jdk21=
    _jdk25=
    _jdk_latest=

    _discover_jdks() {
      for _jdir in "$@"; do
        _jdir=${_jdir%/}
        [ -d "$_jdir" ] || continue
        [ -f "$_jdir/include/jni.h" ] || continue
        [ -x "$_jdir/bin/java" ] || continue
        _jver=$("$_jdir/bin/java" -version 2>&1 | head -1 | sed 's/.*version "\(.*\)".*/\1/' | cut -d'.' -f1)
        case "$_jver" in
          1) # 1.8.x reports as "1.8.0_xxx"
            if [ -z "$_jdk8" ]; then _jdk8="$_jdir"; fi
            ;;
          1[1-9]) # JDK 11-19
            if [ "$_jver" = "17" ] && [ -z "$_jdk17" ]; then _jdk17="$_jdir"; fi
            ;;
          2[1-9]|3*) # JDK 21+
            if [ "$_jver" = "21" ] && [ -z "$_jdk21" ]; then _jdk21="$_jdir"; fi
            if [ "$_jver" = "25" ] && [ -z "$_jdk25" ]; then _jdk25="$_jdir"; fi
            _jdk_latest="$_jdir"
            ;;
        esac
      done
      return 0
    }
    # Discover JDKs: well-known paths first, then /usr/jdk/instances/ and ~/Downloads/
    _jdk_list=
    if [ -d "/export/home/solaris/jdk17" ]; then _jdk_list="/export/home/solaris/jdk17"; fi
    for _d in /usr/jdk/instances/*/; do
      if [ -d "$_d" ]; then _jdk_list="$_jdk_list $_d"; fi
    done
    for _d in ~/Downloads/jdk-*/; do
      if [ -d "$_d" ]; then _jdk_list="$_jdk_list $_d"; fi
    done
    if [ -n "$_jdk_list" ]; then _discover_jdks $_jdk_list; fi
    unset -f _discover_jdks 2>/dev/null || true

    # Pick the best JDK for this LWJGL version
    _lw_major=$(printf '%s' "$LWJGL_VERSION" | cut -d'.' -f1)
    _lw_minor=$(printf '%s' "$LWJGL_VERSION" | cut -d'.' -f2)

    # Kotlin compiler on SPARC Solaris crashes with "Unbalanced tree" on JDK 21+.
    # LWJGL 3.1.x-3.2.x: prefer JDK 8 (has Nashorn), fall back to JDK 17.
    # LWJGL 3.3.x: JDK 17 only (Kotlin "Unbalanced tree" on JDK 21+).
    # LWJGL 3.4+ (MC 26.3+): prefer JDK 25, fall back to JDK 17.
    if [ "$_lw_major" -eq 3 ] 2>/dev/null; then
      if [ "$_lw_minor" -le 2 ] 2>/dev/null; then
        # LWJGL 3.1.x-3.2.x (MC 1.13-1.18): prefer JDK 8 (has Nashorn), fall back to JDK 17
        if [ -n "$_jdk8" ]; then JAVA_HOME="$_jdk8"
        elif [ -n "$_jdk17" ]; then JAVA_HOME="$_jdk17"
        elif [ -n "$_jdk_latest" ]; then JAVA_HOME="$_jdk_latest"
        fi
      elif [ "$_lw_minor" -eq 3 ] 2>/dev/null; then
        # LWJGL 3.3.x (MC 1.19-1.21): JDK 17 only (Kotlin "Unbalanced tree" on JDK 21+)
        if [ -n "$_jdk17" ]; then JAVA_HOME="$_jdk17"
        elif [ -n "$_jdk8" ]; then JAVA_HOME="$_jdk8"
        elif [ -n "$_jdk_latest" ]; then JAVA_HOME="$_jdk_latest"
        fi
      else
        # LWJGL 3.4+ (MC 26.3+): prefer JDK 25, fall back to JDK 17
        if [ -n "$_jdk25" ]; then JAVA_HOME="$_jdk25"
        elif [ -n "$_jdk17" ]; then JAVA_HOME="$_jdk17"
        elif [ -n "$_jdk8" ]; then JAVA_HOME="$_jdk8"
        elif [ -n "$_jdk_latest" ]; then JAVA_HOME="$_jdk_latest"
        fi
      fi
    else
      if [ -n "$_jdk8" ]; then JAVA_HOME="$_jdk8"
      elif [ -n "$_jdk17" ]; then JAVA_HOME="$_jdk17"
      elif [ -n "$_jdk_latest" ]; then JAVA_HOME="$_jdk_latest"
      fi
    fi

    # JAVA8_HOME: only set for LWJGL 3.1.x-3.2.x (boot classpath for javac source=8 target=8)
    # LWJGL 3.3+ uses --release 8 which doesn't need boot classpath; passing
    # --boot-class-path on JDK 17+ causes NullPointerException in javac.
    JAVA8_HOME=
    if [ -n "$_jdk8" ]; then
      case "$LWJGL_VERSION" in
        3.1.*|3.2.*) JAVA8_HOME="$_jdk8" ;;
      esac
    fi

    export JAVA_HOME
    if [ -n "${JAVA8_HOME:-}" ]; then export JAVA8_HOME; fi
  }
  _select_jdk
  unset -f _select_jdk 2>/dev/null || true

  export JAVA_HOME
  if [ -n "${JAVA8_HOME:-}" ]; then log "JAVA8_HOME=$JAVA8_HOME (for LWJGL boot classpath)"; fi
  log "JAVA_HOME=$JAVA_HOME ($($JAVA_HOME/bin/java -version 2>&1 | head -1))"

  # Nashorn is required by LWJGL 3.1.x-3.2.x for <script language="javascript"> in build-bindings.xml.
  # JDK 15+ removed Nashorn; provide standalone Nashorn 15.4+ for modern JDKs.
  _nashorn_lib=
  _root_dir=$(CDPATH= cd "$MCDIR/../.." && pwd)
  if [ -f "$_root_dir/tools/nashorn/nashorn-core.jar" ]; then
    _nashorn_lib="$_root_dir/tools/nashorn"
  fi
  if [ -n "$_nashorn_lib" ]; then
    _java_ver=$($JAVA_HOME/bin/java -version 2>&1 | head -1 | sed 's/.*version "\(.*\)".*/\1/' | cut -d'.' -f1)
    case "$_java_ver" in
      1) ;; # JDK 8 has Nashorn built-in
      *) export ANT_ARGS="-lib $_nashorn_lib ${ANT_ARGS:-}" ;;
    esac
  fi
  if [ -n "${ANT_ARGS:-}" ]; then log "ANT_ARGS=$ANT_ARGS (Nashorn for LWJGL bindings)"; fi

  if [ "$#" -eq 0 ]; then set -- $COMPONENTS verify; fi
  log "Minecraft $MC_VERSION  (LWJGL $LWJGL_VERSION)  ->  $OUT"
  is_dry || mkdir -p "$OUT" "$WORK"
  for _c in "$@"; do
    case "$_c" in
      libffi)   comp_libffi ;;
      glfw)     comp_glfw ;;
      lwjgl3)   comp_lwjgl3 ;;
      jemalloc) comp_jemalloc ;;
      openal)   comp_openal ;;
      sdl3)     comp_sdl3 ;;
      freetype) comp_freetype ;;
      shaderc)  comp_shaderc ;;
      spvc)     comp_spvc ;;
      verify)   if [ -z "${PREPARE_ONLY:-}" ]; then verify_natives; fi ;;
      *) die "unknown component '$_c' (libffi glfw lwjgl3 jemalloc openal sdl3 freetype shaderc spvc verify)" ;;
    esac
  done
  log "done: $OUT"
}
