#!/usr/xpg4/bin/sh
# Build and stage LWJGL native binaries for SPARC Solaris.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)
VERSION=${1-}
GLFW_SRC=${GLFW_SRC:-$HOME/git/glfw}
LWJGL_SRC=${LWJGL_SRC:-$HOME/git/lwjgl3}
SDL3_SRC=${SDL3_SRC:-$HOME/git/SDL}
NATIVES_SRC=${NATIVES_SRC:-$HOME/.minecraft/natives/1.20.1}
GLFW_BUILD=${GLFW_BUILD:-$GLFW_SRC/build-shared}

usage() { echo "usage: $0 VERSION [glfw|lwjgl3|sdl3|natives|existing] ..." >&2; exit 2; }
[ -n "$VERSION" ] || usage
case "$VERSION" in
  1.13|1.14|1.15|1.16|1.17|1.18|1.19|1.20|1.20.1|1.21|26.1|26.2|26.3) ;;
  *) echo "unsupported main release: $VERSION" >&2; exit 2 ;;
esac
OUT=${OUT:-$ROOT/bin/$VERSION}
WORK=${WORK:-$ROOT/work/$VERSION}
mkdir -p "$OUT" "$WORK"

copy_tree() {
  src=$1; dst=$2
  [ -d "$src" ] || { echo "missing directory: $src" >&2; exit 1; }
  mkdir -p "$dst"
  (cd "$src" && tar cf - .) | (cd "$dst" && tar xpf -)
}
apply_component() {
  name=$1; src=$2; version=$3
  [ -d "$src" ] || { echo "missing $name checkout: $src" >&2; exit 1; }
  dst=$WORK/$name
  rm -rf "$dst"
  copy_tree "$src" "$dst"
  patchdir=$ROOT/patches/$name/$version
  if [ -d "$patchdir" ]; then
    for p in "$patchdir"/*.patch; do
      [ -f "$p" ] || continue
      (cd "$dst" && patch -N -p1 < "$p") || { echo "patch failed: $p" >&2; exit 1; }
    done
  fi
  echo "$name source prepared at $dst"
}
stage_tree() { copy_tree "$1" "$OUT"; }

shift
[ "$#" -gt 0 ] || set -- natives existing
for component in "$@"; do
  case "$component" in
    glfw) apply_component glfw "$GLFW_SRC" 3.6.0 ;;
    lwjgl3) apply_component lwjgl3 "$LWJGL_SRC" "$VERSION" ;;
    sdl3)
      case "$VERSION" in
        26.3) apply_component sdl3 "$SDL3_SRC" "$VERSION" ;;
        *) echo "SDL3 Vulkan patches are only enabled for 26.3+; no matching release in versions.conf" >&2; exit 2 ;;
      esac ;;
    natives) stage_tree "$NATIVES_SRC" ;;
    existing) stage_tree "$GLFW_BUILD/src" ;;
    *) usage ;;
  esac
done
echo "staged output: $OUT"
