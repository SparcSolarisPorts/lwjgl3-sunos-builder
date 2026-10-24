#!/usr/xpg4/bin/sh
# Deploy built natives and JARs to ~/.minecraft for a given version.
#
#   ./tools/deploy.sh VERSION
#   ./tools/deploy.sh all
#
# Copies:
#   - JARs from bin/VERSION/lwjgl/<lwjgl_version>/ to ~/.minecraft/libraries/org/lwjgl/
#   - Natives (.so) from bin/VERSION/ to ~/.minecraft/versions/VERSION/natives/
#   - lwjgl.jar (patched core) to ~/.minecraft/versions/VERSION/lwjgl.jar
#
# Env: MINECRAFT_HOME overrides ~/.minecraft
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/common.sh"

[ -x /usr/xpg4/bin/sh ] && SH=/usr/xpg4/bin/sh || SH=sh

versions() { grep -v '^#' "$ROOT/versions.conf" | cut -d'|' -f1; }

mc_home=${MINECRAFT_HOME:-$HOME/.minecraft}

deploy_version() {
  _v=$1
  _bin=$ROOT/bin/$_v
  [ -d "$_bin" ] || { warn "no build output for $_v"; return 1; }

  # Read LWJGL version from version.env
  _env=$ROOT/mc/$_v/version.env
  [ -f "$_env" ] || { warn "no version.env for $_v"; return 1; }
  _lwjgl_ver=$(grep '^LWJGL_VERSION=' "$_env" | head -1 | cut -d'=' -f2)
  [ -n "$_lwjgl_ver" ] || { warn "LWJGL_VERSION not found for $_v"; return 1; }

  # --- Deploy natives to ~/.minecraft/versions/<version>/natives/ ---
  _natives_dir=$mc_home/versions/$_v/natives
  mkdir -p "$_natives_dir"
  _native_count=0
  for _so in "$_bin"/*.so; do
    [ -f "$_so" ] || continue
    cp -f "$_so" "$_natives_dir/" 2>/dev/null && _native_count=$((_native_count + 1)) || true
  done
  log "deployed $_native_count native libraries to $_natives_dir/"

  # --- Deploy lwjgl.jar (patched core) ---
  if [ -f "$_bin/lwjgl.jar" ]; then
    cp -f "$_bin/lwjgl.jar" "$mc_home/versions/$_v/lwjgl.jar"
    log "deployed lwjgl.jar to $mc_home/versions/$_v/"
  fi

  # --- Deploy LWJGL module JARs to ~/.minecraft/libraries/org/lwjgl/ ---
  _lwjgl_dir=$_bin/lwjgl/$_lwjgl_ver
  if [ -d "$_lwjgl_dir" ]; then
    _lib_base=$mc_home/libraries/org/lwjgl
    _jar_count=0
    for _jar in "$_lwjgl_dir"/*.jar; do
      [ -f "$_jar" ] || continue
      _jar_name=$(basename "$_jar")
      # Derive Maven coordinates: lwjgl.jar -> lwjgl:lwjgl:VERSION; lwjgl-<mod>.jar -> lwjgl:lwjgl-<mod>:VERSION
      _base=${_jar_name%.jar}
      _group=lwjgl
      _artifact=$_base
      _lib_dir=$_lib_base/$_artifact/$_lwjgl_ver
      mkdir -p "$_lib_dir"
      cp -f "$_jar" "$_lib_dir/$_jar_name" 2>/dev/null && _jar_count=$((_jar_count + 1)) || true
    done
    [ "$_jar_count" -gt 0 ] && log "deployed $_jar_count LWJGL JARs to $_lib_base/"
  else
    warn "no LWJGL module JARs at $_lwjgl_dir"
  fi

  log "deployed $_v -> $mc_home"
}

[ "$#" -ge 1 ] || { echo "usage: $0 VERSION | all" >&2; exit 2; }
case "$1" in
  all)
    for v in $(versions); do
      echo "######## Deploy $_v"
      deploy_version "$v" || { echo "FAILED: $v" >&2; FAILED="${FAILED-} $v"; }
    done
    [ -z "${FAILED-}" ] || { echo "failed versions:${FAILED}" >&2; exit 1; }
    ;;
  *)
    deploy_version "$1"
    ;;
esac
