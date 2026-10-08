#!/usr/xpg4/bin/sh
# Shared helpers for lwjgl3-sunos-builder. Sourced by mc/<version>/build.sh.
# POSIX sh only (no arrays, no [[ ]], no local) so it runs under Solaris
# /usr/xpg4/bin/sh.

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

is_dry() { [ -n "${DRY_RUN:-}" ]; }

# run CMD...  -- execute, or only print when DRY_RUN is set
run() {
  if is_dry; then printf '+ %s\n' "$*" >&2; else "$@"; fi
}

need() { # need TOOL...  -- fail early when a build tool is missing
  for _t in "$@"; do
    command -v "$_t" >/dev/null 2>&1 || is_dry || die "required tool not found: $_t"
  done
}

first_tool() { # first_tool A B C -> prints the first that exists, else the last
  for _t in "$@"; do
    if command -v "$_t" >/dev/null 2>&1; then printf '%s\n' "$_t"; return 0; fi
  done
  printf '%s\n' "$_t"
}

# ---------------------------------------------------------------- fetching

# mirror_repo NAME URL  -- ensure a bare mirror in $CACHE, sets $MIRROR.
# Each mirror is refreshed at most once per process.
_MIRRORED=
mirror_repo() {
  _key=$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')
  MIRROR=$CACHE/$1-$_key.git
  mkdir -p "$CACHE"
  case " $_MIRRORED " in *" $MIRROR "*) return 0 ;; esac
  if [ -d "$MIRROR" ]; then
    if [ -z "${OFFLINE:-}" ]; then
      log "updating mirror $1 ($2)"
      run git -C "$MIRROR" remote update --prune >/dev/null 2>&1 || return 1
    fi
  else
    if [ -n "${OFFLINE:-}" ] && ! is_dry; then
      warn "OFFLINE set but no cached mirror for $1"; return 1
    fi
    log "mirroring $1 ($2)"
    run git clone -q --mirror "$2" "$MIRROR" || return 1
  fi
  _MIRRORED="$_MIRRORED $MIRROR"
}

# fetch_src NAME URL REF DST
# Clones the cached mirror to DST and checks out REF (tag, branch or sha).
# External checkouts are never touched.
fetch_src() {
  _name=$1; _url=$2; _ref=$3; _dst=$4
  mirror_repo "$_name" "$_url" || die "cannot mirror $_url"
  run rm -rf "$_dst"
  run mkdir -p "$(dirname "$_dst")"
  run git clone -q "$MIRROR" "$_dst"
  if is_dry; then printf '+ git -C %s checkout %s\n' "$_dst" "$_ref" >&2; return 0; fi
  git -C "$_dst" checkout -q "$_ref" 2>/dev/null ||
    git -C "$_dst" checkout -q "origin/$_ref" 2>/dev/null ||
    die "ref '$_ref' not found in $_url (try: git ls-remote --tags $_url)"
  log "$_name at $(git -C "$_dst" rev-parse --short HEAD) ($_ref)"
}

# ---------------------------------------------------------------- patching

# apply_patches DIR PATCHDIR
# Applies PATCHDIR/*.patch in lexical order. Already-applied patches are
# skipped, so re-running is safe. Uses `git apply` (exact context, handles
# renames/new files). Fallbacks: ALLOW_3WAY=1 (git apply --3way), then
# ALLOW_FUZZ=1 (patch(1) with fuzz).
apply_patches() {
  _dir=$1; _pd=$2
  [ -d "$_pd" ] || return 0
  _n=0
  for _p in "$_pd"/*.patch; do
    [ -f "$_p" ] || continue
    _n=$((_n + 1))
    _b=$(basename "$_p")
    if is_dry; then printf '+ apply %s in %s\n' "$_p" "$_dir" >&2; continue; fi
    if (cd "$_dir" && git apply -R --check "$_p") >/dev/null 2>&1; then
      log "  already applied: $_b"
    elif (cd "$_dir" && git apply --check "$_p") >/dev/null 2>&1; then
      (cd "$_dir" && git apply --whitespace=nowarn "$_p") || die "git apply failed: $_p"
      log "  applied: $_b"
    elif [ -n "${ALLOW_3WAY:-}" ] &&
         (cd "$_dir" && git apply --3way --whitespace=nowarn "$_p") >/dev/null 2>&1; then
      warn "applied with --3way (review the result): $_b"
    elif [ -n "${ALLOW_FUZZ:-}" ] &&
         (cd "$_dir" && $PATCH_CMD -p1 -F3 --no-backup-if-mismatch < "$_p") >/dev/null 2>&1; then
      warn "applied with fuzz: $_b"
    else
      die "patch does not apply: $_p (tree: $_dir). Regenerate it with tools/extract-fork-patches.sh or fix by hand."
    fi
  done
  [ "$_n" -gt 0 ] || log "  (no patches in $_pd)"
}

# prepare NAME URL REF DST PATCHSUBDIR
prepare() {
  fetch_src "$1" "$2" "$3" "$4"
  log "patching $1 from $5"
  apply_patches "$4" "$5"
}

# ---------------------------------------------------------------- building

cmake_build() { # cmake_build NAME SRCDIR [cmake args...]
  _n=$1; _s=$2; shift 2
  _b=$WORK/build/$_n
  run rm -rf "$_b"
  run mkdir -p "$_b"
  ( cd "$_b" 2>/dev/null || is_dry
    run env CC="$CC" CXX="$CXX" "$CMAKE" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_C_FLAGS="$ARCH_FLAGS $CFLAGS" \
      -DCMAKE_CXX_FLAGS="$ARCH_FLAGS $CXXFLAGS" \
      "$@" "$_s" )
  ( cd "$_b" 2>/dev/null || is_dry
    run "$MAKE" -j "$JOBS" )
  BUILD_DIR=$_b
}

# stage_lib BUILDDIR FINDPATTERN OUTNAME
# Copies the real (non-symlink) file, so OUT never holds dangling links.
stage_lib() {
  is_dry && { printf '+ stage %s/%s -> %s/%s\n' "$1" "$2" "$OUT" "$3" >&2; return 0; }
  _f=$(find "$1" -name "$2" -type f 2>/dev/null | head -1)
  [ -n "$_f" ] || die "no build output matching '$2' under $1"
  mkdir -p "$OUT"
  cp "$_f" "$OUT/$3"
  log "staged $3  <-  ${_f#$WORK/}"
}

# elf_check FILE -> 0 when FILE is a 64-bit big-endian SPARCV9 ELF object
elf_check() {
  _h=$(od -An -v -tx1 -N20 "$1" 2>/dev/null | tr -d ' \n')
  _magic=$(printf '%s' "$_h" | cut -c1-8)
  _class=$(printf '%s' "$_h" | cut -c9-10)
  _data=$(printf '%s' "$_h" | cut -c11-12)
  _mach=$(printf '%s' "$_h" | cut -c37-40)
  [ "$_magic" = 7f454c46 ] && [ "$_class" = 02 ] && [ "$_data" = 02 ] &&
    [ "$_mach" = "${EXPECT_MACHINE:-002b}" ]
}

verify_natives() {
  is_dry && { printf '+ verify %s in %s\n' "$NATIVES" "$OUT" >&2; return 0; }
  _bad=0
  for _f in $NATIVES; do
    if [ ! -f "$OUT/$_f" ]; then
      printf 'MISSING  %s\n' "$_f" >&2; _bad=$((_bad + 1))
    elif ! elf_check "$OUT/$_f"; then
      printf 'WRONG-ELF %s (want 64-bit MSB, e_machine 0x%s)\n' "$_f" "${EXPECT_MACHINE:-002b}" >&2
      _bad=$((_bad + 1))
    else
      printf 'ok       %s\n' "$_f" >&2
    fi
  done
  [ "$_bad" -eq 0 ] || die "$_bad native(s) missing or not SPARCV9 in $OUT"
  log "all $(printf '%s\n' $NATIVES | wc -l | tr -d ' ') natives present for Minecraft $MC_VERSION"
}
