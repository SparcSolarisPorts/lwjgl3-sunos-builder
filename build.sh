#!/usr/xpg4/bin/sh
# lwjgl3-sunos-builder: build SPARC Solaris natives for a Minecraft release.
#
#   ./build.sh list
#   ./build.sh clean
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
  echo "usage: $0 list | clean | check | all | VERSION [component ...]" >&2
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
  clean)
    # Remove generated outputs and cached mirrors. The next check/build will
    # clone fresh mirrors and fetch all tags, including the pinned refs.
    rm -rf "$ROOT/bin" "$ROOT/work" "$ROOT/build" "$ROOT/cache"
    echo "removed bin/, work/, build/, and cache/" ;;
  check)
    shift; exec "$SH" "$ROOT/tools/check-patches.sh" "$@" ;;
  all)
    shift
    # Determine parallelism: use all CPU cores by default, capped at the number
    # of versions to avoid spawning more jobs than there are tasks.
    _n_versions=$(versions | wc -l | tr -d ' ')
    _n_cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    case "$_n_cpus" in ''|*[!0-9]*) _n_cpus=4 ;; esac
    _parallel=$_n_cpus
    [ "$_parallel" -gt "$_n_versions" ] && _parallel=$_n_versions
    printf '==> building all versions with %s parallel job(s)\n' "$_parallel" >&2
    FAILED=
    _pids=""
    _pid_vers=""
    for v in $(versions); do
      # Throttle: poll running PIDs until a slot opens
      while true; do
        _running=0
        _new_pids=""
        _new_vers=""
        for _i in $_pids; do
          if kill -0 "$_i" 2>/dev/null; then
            _new_pids="$_new_pids $_i"
            _running=$((_running + 1))
          fi
        done
        _pids=$_new_pids
        [ "$_running" -lt "$_parallel" ] && break
        sleep 3
      done
      echo "######## Minecraft $v"
      ( "$SH" "$ROOT/mc/$v/build.sh" "$@" 2>&1 | tee "$ROOT/build_${v}.log"
        echo $? > "$ROOT/build_${v}_exit.log" ) &
      _pid=$!
      _pids="$_pids $_pid"
      _pid_vers="$_pid_vers $_pid:$v"
    done
    # Wait for all remaining jobs
    wait
    # Check exit codes
    for v in $(versions); do
      if [ -f "$ROOT/build_${v}_exit.log" ]; then
        _exit_code=$(tail -1 "$ROOT/build_${v}_exit.log" 2>/dev/null || echo 1)
        case "$_exit_code" in 0) ;; *) FAILED="${FAILED-} $v" ;; esac
        rm -f "$ROOT/build_${v}_exit.log"
      fi
    done
    [ -z "${FAILED-}" ] || { echo "failed versions:${FAILED}" >&2; exit 1; }
    printf '==> all versions built successfully\n' >&2 ;;
  *)
    v=$1; shift
    [ -f "$ROOT/mc/$v/build.sh" ] || { echo "unsupported release: $v" >&2; usage; }
    exec "$SH" "$ROOT/mc/$v/build.sh" "$@" ;;
esac
