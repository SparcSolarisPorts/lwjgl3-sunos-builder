#!/usr/xpg4/bin/sh
# Dry-run every release's patch sets against the exact upstream ref it pins and
# report which ones do NOT apply cleanly. Nothing is checked out, built or
# modified: patches are applied in order to a throw-away index built from the
# cached bare mirror, so patch 2 sees the result of patch 1 (as in a real build).
#
#   tools/check-patches.sh [-v] [--3way] [--offline] [MC ...]
#   ./build.sh check ...            (same thing)
#
#   -v         show every patch's verdict, not just failures
#   --3way     also try `git apply --3way`; such patches are reported as 3WAY
#              (the builder applies them only with ALLOW_3WAY=1)
#   --offline  reuse cached mirrors, don't touch the network
#
# Refs come from mc/<ver>/version.env and can be overridden for an experiment:
#   GLFW_REF=3.4 tools/check-patches.sh 1.20.1
#
# Status per release/component:
#   OK       every patch applies (or is already applied) with exact context
#   3WAY     applies only through a 3-way merge (--3way)
#   FAIL n/m n of m patches do not apply
#   NOREF    the pinned tag/branch does not exist upstream
#   NOFETCH  the repository could not be mirrored (network? URL?)
#   -        no patches for that component
# Exit status: 0 = everything OK (or 3WAY with --3way), 1 = anything else.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/common.sh"
CACHE=${CACHE:-$ROOT/cache}
VERBOSE=; THREEWAY=; MCS=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1 ;;
    --3way) THREEWAY=1 ;;
    --offline) OFFLINE=1; export OFFLINE ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) MCS="$MCS $1" ;;
  esac
  shift
done
[ -n "$MCS" ] || MCS=$(grep -v '^#' "$ROOT/versions.conf" | cut -d'|' -f1)
need git cksum

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/memo"
: > "$TMP/members"

COMPS="lwjgl3 glfw sdl3 libffi jemalloc openal freetype shaderc spvc"
upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
comp_var() { case "$1" in lwjgl3) echo LWJGL ;; *) upper "$1" ;; esac; }

# component_active ENV COMPONENT -- version.env's COMPONENTS list is the
# build's source of truth.  Ignore stale patch directories copied from another
# release instead of trying to resolve refs for components that are not built.
component_active() {
  _env=$1; _want=$2
  _components=$(sh -c '. "$1"; printf "%s" "${COMPONENTS-}"' sh "$_env")
  for _c in $_components; do
    [ "$_c" = "$_want" ] && return 0
  done
  return 1
}

# component_metadata ENV COMPONENT -> URL and ref, one per line.  Keep the
# variable mapping explicit: Solaris /usr/xpg4/bin/sh has no POSIX indirect
# parameter expansion, and the old eval-based lookup could return empty values
# for valid component variables on that shell.
component_metadata() {
  _env=$1; _comp=$2
  (
    . "$_env"
    case "$_comp" in
      lwjgl3)  printf '%s\n%s\n' "${LWJGL_URL-}"  "${LWJGL_REF-}" ;;
      glfw)    printf '%s\n%s\n' "${GLFW_URL-}"   "${GLFW_REF-}" ;;
      sdl3)    printf '%s\n%s\n' "${SDL3_URL-}"   "${SDL3_REF-}" ;;
      libffi)  printf '%s\n%s\n' "${LIBFFI_URL-}" "${LIBFFI_REF-}" ;;
      jemalloc) printf '%s\n%s\n' "${JEMALLOC_URL-}" "${JEMALLOC_REF-}" ;;
      openal)  printf '%s\n%s\n' "${OPENAL_URL-}" "${OPENAL_REF-}" ;;
      freetype) printf '%s\n%s\n' "${FREETYPE_URL-}" "${FREETYPE_REF-}" ;;
      shaderc) printf '%s\n%s\n' "${SHADERC_URL-}" "${SHADERC_REF-}" ;;
      spvc)    printf '%s\n%s\n' "${SPVC_URL-}"    "${SPVC_REF-}" ;;
    esac
  )
}

# _check MIRROR COMMIT PATCHDIR OUTPREFIX -- runs in a subshell so the GIT_*
# variables never leak. Writes OUTPREFIX.status and OUTPREFIX.detail.
_check() {
  (
    export GIT_DIR=$1 GIT_INDEX_FILE=$TMP/index.$$
    rm -f "$GIT_INDEX_FILE"
    git read-tree "$2"
    total=0; bad=0; way=0
    : > "$4.detail"
    for p in "$3"/*.patch; do
      [ -f "$p" ] || continue
      total=$((total + 1)); b=$(basename "$p")
      if git apply --cached -R --check "$p" >/dev/null 2>&1; then
        [ -z "$VERBOSE" ] || echo "    $b: already applied" >> "$4.detail"
      elif git apply --cached --check "$p" 2> "$TMP/err.$$"; then
        git apply --cached "$p"
        [ -z "$VERBOSE" ] || echo "    $b: clean" >> "$4.detail"
      else
        cp "$GIT_INDEX_FILE" "$GIT_INDEX_FILE.bak"
        if [ -n "$THREEWAY" ] && git apply --cached --3way "$p" >/dev/null 2>&1; then
          way=$((way + 1)); echo "    $b: applies only with --3way" >> "$4.detail"
        else
          [ -z "$THREEWAY" ] || cp "$GIT_INDEX_FILE.bak" "$GIT_INDEX_FILE"
          bad=$((bad + 1)); echo "    $b: DOES NOT APPLY" >> "$4.detail"
          grep '^error:' "$TMP/err.$$" | sed -n '1,8p' | sed 's/^error: /        /' >> "$4.detail"
        fi
      fi
    done
    if [ "$bad" -gt 0 ]; then echo "FAIL $bad/$total" > "$4.status"
    elif [ "$way" -gt 0 ]; then echo "3WAY" > "$4.status"
    else echo "OK" > "$4.status"; fi
  )
}

for mc in $MCS; do
  envf=$ROOT/mc/$mc/version.env
  [ -f "$envf" ] || { warn "no mc/$mc/version.env, skipping"; continue; }
  for comp in $COMPS; do
    if ! component_active "$envf" "$comp"; then
      echo "-" > "$TMP/st.$mc.$comp"
      continue
    fi
    pd=$ROOT/mc/$mc/patches/$comp
    n=$(ls "$pd"/*.patch 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -eq 0 ]; then echo "-" > "$TMP/st.$mc.$comp"; continue; fi
    metadata=$(component_metadata "$envf" "$comp")
    url=$(printf '%s\n' "$metadata" | sed -n '1p')
    ref=$(printf '%s\n' "$metadata" | sed -n '2p')
    if [ -z "$url" ] || [ -z "$ref" ]; then echo "NOREF" > "$TMP/st.$mc.$comp"; continue; fi
    if ! mirror_repo "$comp" "$url" 2>/dev/null; then
      echo "NOFETCH" > "$TMP/st.$mc.$comp"
      printf '%s %s %s %s\n' "nofetch-$comp" "$comp" "$mc" "$url" >> "$TMP/members"
      echo "    cannot mirror $url" > "$TMP/memo/nofetch-$comp.detail"; echo NOFETCH > "$TMP/memo/nofetch-$comp.status"
      continue
    fi
    commit=$(git --git-dir="$MIRROR" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)
    if [ -z "$commit" ]; then
      echo "NOREF" > "$TMP/st.$mc.$comp"
      k=noref-$comp-$(printf '%s' "$ref" | tr -c 'A-Za-z0-9.' _)
      printf '%s %s %s %s\n' "$k" "$comp" "$mc" "$ref" >> "$TMP/members"
      echo NOREF > "$TMP/memo/$k.status"
      echo "    ref '$ref' not found; try: git ls-remote --tags $url" > "$TMP/memo/$k.detail"
      continue
    fi
    # identical (commit, patch-set) pairs are only checked once
    sum=$(cat "$pd"/*.patch | cksum | tr ' ' _)
    k=$comp-$commit-$sum
    [ -f "$TMP/memo/$k.status" ] || _check "$MIRROR" "$commit" "$pd" "$TMP/memo/$k"
    cp "$TMP/memo/$k.status" "$TMP/st.$mc.$comp"
    printf '%s %s %s %s\n' "$k" "$comp" "$mc" "$ref" >> "$TMP/members"
  done
done

# ------------------------------------------------------------------ report
active=
for comp in $COMPS; do
  for mc in $MCS; do
    [ -f "$TMP/st.$mc.$comp" ] && [ "$(cat "$TMP/st.$mc.$comp")" != "-" ] && { active="$active $comp"; break; }
  done
done
echo
printf '%-10s' MC; for c in $active; do printf '%-12s' "$c"; done; echo
printf '%-10s' ------; for c in $active; do printf '%-12s' --------; done; echo
rc=0
for mc in $MCS; do
  [ -f "$TMP/st.$mc.lwjgl3" ] || [ -f "$TMP/st.$mc.glfw" ] || continue
  printf '%-10s' "$mc"
  for c in $active; do
    s=$(cat "$TMP/st.$mc.$c" 2>/dev/null || echo -)
    printf '%-12s' "$s"
    case "$s" in OK|-) ;; 3WAY) [ -n "$THREEWAY" ] || rc=1 ;; *) rc=1 ;; esac
  done
  echo
done

if [ "$rc" -ne 0 ] || [ -n "$VERBOSE" ]; then
  echo; echo "Details (releases sharing the same source ref and patch set are grouped):"
  for k in $(cut -d' ' -f1 "$TMP/members" | sort -u); do
    s=$(cat "$TMP/memo/$k.status")
    [ -n "$VERBOSE" ] || [ "$s" != OK ] || continue
    comp=$(grep "^$k " "$TMP/members" | head -1 | cut -d' ' -f2)
    ref=$(grep "^$k " "$TMP/members" | head -1 | cut -d' ' -f4-)
    who=$(grep "^$k " "$TMP/members" | cut -d' ' -f3 | tr '\n' ' ')
    echo; echo "[$comp @ $ref] $s -- Minecraft: $who"
    cat "$TMP/memo/$k.detail"
  done
  ALLST=$(cat "$TMP"/st.* 2>/dev/null)
  if printf '%s\n' "$ALLST" | grep -q '^FAIL'; then
    echo
    echo "FAIL: port the patch for that ref (tools/extract-fork-patches.sh replays the fork's"
    echo "commits onto each tag and lists conflicts), or pin a ref the patch fits in"
    echo "mc/<ver>/version.env. --3way shows which ones a 3-way merge could rescue."
  fi
  if printf '%s\n' "$ALLST" | grep -q '^NOFETCH'; then
    echo; echo "NOFETCH: check network/proxy access to the URL above (or run once online, then --offline)."
  fi
  if printf '%s\n' "$ALLST" | grep -q '^NOREF'; then
    echo; echo "NOREF: the tag/branch in mc/<ver>/version.env does not exist in that repository."
  fi
fi
exit $rc
