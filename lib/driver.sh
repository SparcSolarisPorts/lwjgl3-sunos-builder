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
  export JAVA_HOME

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
