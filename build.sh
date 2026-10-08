#!/usr/xpg4/bin/sh
# lwjgl3-sunos-builder: build SPARC Solaris natives for a Minecraft release.
#
#   ./build.sh list
#   ./build.sh VERSION [glfw|lwjgl3|jemalloc|openal|sdl3|verify ...]
#   ./build.sh all
#   ./build.sh check [-v] [--3way] [--offline] [VERSION ...]   dry-run all patch sets
#
# Each release lives in mc/VERSION/ (build.sh, version.env, patches/).
# Env: PREPARE_ONLY=1  fetch+patch only     DRY_RUN=1  print, don't execute
#      OFFLINE=1       reuse cached mirrors JAVA_HOME  SPARCV9 JDK (for LWJGL)
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)
if [ -x /usr/xpg4/bin/sh ]; then SH=/usr/xpg4/bin/sh; else SH=sh; fi

versions() { grep -v '^#' "$ROOT/versions.conf" | cut -d'|' -f1; }
usage() {
  echo "usage: $0 list | check | all | VERSION [component ...]" >&2
  echo "versions: $(versions | tr '\n' ' ')" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
case "$1" in
  -h|--help) usage ;;
  list)
    printf '%-8s %-7s %s\n' MC LWJGL SDL3
    grep -v '^#' "$ROOT/versions.conf" | while IFS='|' read mc lw sdl; do
      printf '%-8s %-7s %s\n' "$mc" "$lw" "$sdl"
    done ;;
  check)
    shift; exec "$SH" "$ROOT/tools/check-patches.sh" "$@" ;;
  all)
    shift
    for v in $(versions); do
      echo "######## Minecraft $v"
      "$SH" "$ROOT/mc/$v/build.sh" "$@" || { echo "FAILED: $v" >&2; FAILED="${FAILED-} $v"; }
    done
    [ -z "${FAILED-}" ] || { echo "failed versions:${FAILED}" >&2; exit 1; } ;;
  *)
    v=$1; shift
    [ -f "$ROOT/mc/$v/build.sh" ] || { echo "unsupported release: $v" >&2; usage; }
    exec "$SH" "$ROOT/mc/$v/build.sh" "$@" ;;
esac
