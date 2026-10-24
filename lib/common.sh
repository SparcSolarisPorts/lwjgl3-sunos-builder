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

# create_mirror NAME URL -- initialize and fetch a mirror without `git clone`.
# Some older Solaris Git releases misparse an absolute clone destination as a
# protocol name, so initialize the bare repository from inside CACHE instead.
create_mirror() {
  _name=$1; _url=$2
  _mirror_name=$_name-$(printf '%s' "$_url" | sed 's/[^A-Za-z0-9]/_/g').git
  if is_dry; then
    printf '+ git init --bare %s/%s\n' "$CACHE" "$_mirror_name" >&2
    printf '+ git -C %s fetch %s\n' "$CACHE/$_mirror_name" "$_url" >&2
    return 0
  fi
  ( CDPATH= cd "$CACHE" &&
    mkdir "$_mirror_name" &&
    CDPATH= cd "$_mirror_name" &&
    run git init --bare . >/dev/null &&
    run git remote add origin "$_url" &&
    run git fetch --prune origin \
      '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' )
}

mirror_repo() {
  _key=$(printf '%s' "$2" | sed 's/[^A-Za-z0-9]/_/g')
  MIRROR=$CACHE/$1-$_key.git
  is_dry || mkdir -p "$CACHE"
  case " $_MIRRORED " in *" $MIRROR "*) return 0 ;; esac
  if is_dry; then
    printf '+ ensure mirror %s from %s\n' "$MIRROR" "$2" >&2
  elif [ -d "$MIRROR" ]; then
    if [ -z "${OFFLINE:-}" ]; then
      log "updating mirror $1 ($2)"
      # Keep the remote URL correct when recovering a mirror created by an
      # older Solaris Git. Run Git from inside the mirror: some Solaris Git
      # builds misparse absolute -C paths as protocol names.
      if ! ( CDPATH= cd "$MIRROR" &&
             git remote set-url origin "$2" >/dev/null 2>&1 &&
             git fetch --prune origin \
               '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' >/dev/null 2>&1 ); then
        warn "recreating invalid mirror $MIRROR"
        rm -rf "$MIRROR"
        create_mirror "$1" "$2" || return 1
      fi
    fi
  else
    if [ -n "${OFFLINE:-}" ] && ! is_dry; then
      warn "OFFLINE set but no cached mirror for $1"; return 1
    fi
    log "mirroring $1 ($2)"
    # Clone from inside CACHE with a relative destination. This avoids an
    # old Solaris Git argument parser treating the absolute destination as a
    # protocol name, while MIRROR remains absolute for later operations.
    create_mirror "$1" "$2" || return 1
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

# cache_valid_name NAME -- accept only simple, relative output names.
cache_valid_name() {
  case "$1" in
    ''|.|..|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# cache_checksum FILE -- set CACHE_SUM to the portable checksum and byte count.
cache_checksum() {
  _cs_line=$(cksum "$1") || return 1
  set -- $_cs_line
  [ "$#" -ge 2 ] || return 1
  CACHE_SUM="$1 $2"
}

# cache_digest TEXT -- set CACHE_DIGEST, preferring a wide digest when present.
cache_digest() {
  _cd_out=
  if command -v sha256sum >/dev/null 2>&1; then
    _cd_out=$(printf '%s' "$1" | sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    _cd_out=$(printf '%s' "$1" | shasum -a 256) || return 1
  fi
  if [ -n "$_cd_out" ]; then
    set -- $_cd_out
    CACHE_DIGEST=$1
  else
    _cd_out=$(printf '%s' "$1" | cksum) || return 1
    set -- $_cd_out
    [ "$#" -ge 2 ] || return 1
    CACHE_DIGEST="$1_$2"
  fi
}

# cache_tool_version COMMAND... -- set CACHE_TOOL_VERSION to its first output line.
cache_tool_version() {
  _ct_out=$($@ 2>&1) || _ct_out=
  _ct_out=$(printf '%s\n' "$_ct_out" | awk 'NF { print; exit }')
  CACHE_TOOL_VERSION=${_ct_out:-unknown}
}

# cache_tool_fingerprint COMMAND -- include resolved path and executable bytes.
cache_tool_fingerprint() {
  _ct_path=$(command -v "$1" 2>/dev/null) || { CACHE_SAFE=0; CACHE_TOOL_FINGERPRINT=unknown; return 0; }
  [ -f "$_ct_path" ] && [ -r "$_ct_path" ] || { CACHE_SAFE=0; CACHE_TOOL_FINGERPRINT=unknown; return 0; }
  cache_checksum "$_ct_path" || { CACHE_SAFE=0; CACHE_TOOL_FINGERPRINT=unknown; return 0; }
  CACHE_TOOL_FINGERPRINT="$_ct_path:$CACHE_SUM"
}

# cache_dependency_fingerprint DIR -- emit a stable commit/worktree fingerprint.
cache_dependency_fingerprint() {
  _cdf_dir=$1
  _cdf_prefix=$(git -C "$_cdf_dir" rev-parse --show-prefix 2>/dev/null) || return 1
  [ -z "$_cdf_prefix" ] || return 1
  _cdf_head=$(git -C "$_cdf_dir" rev-parse HEAD 2>/dev/null) || return 1
  _cdf_diff=$(git -C "$_cdf_dir" diff --binary HEAD 2>/dev/null) || return 1
  _cdf_digest=$(printf '%s' "$_cdf_diff" | cksum) || return 1
  _cdf_files=$(git -C "$_cdf_dir" ls-files --others --exclude-standard 2>/dev/null) || return 1
  _cdf_extra=
  while IFS= read -r _cdf_file; do
    [ -n "$_cdf_file" ] || continue
    [ ! -L "$_cdf_dir/$_cdf_file" ] && [ -f "$_cdf_dir/$_cdf_file" ] || return 1
    cache_checksum "$_cdf_dir/$_cdf_file" || return 1
    _cdf_extra="$_cdf_extra;$_cdf_file=$CACHE_SUM"
  done <<EOF
$_cdf_files
EOF
  printf '%s;diff=%s;untracked=%s' "$_cdf_head" "$_cdf_digest" "$_cdf_extra"
}

# cache_identity NAME SRCDIR PATCHDIR EXTRA
# Sets CACHE_KEY and CACHE_ID from the resolved source, ordered patch contents,
# recipe parameters, target flags, selected toolchain versions and environment.
cache_identity() {
  _ci_name=$1; _ci_src=$2; _ci_patchdir=$3; _ci_extra=$4; _ci_exclude=${5:-}
  CACHE_SAFE=1
  cache_valid_name "$_ci_name" || die "invalid cache component name: $_ci_name"
  if is_dry; then
    CACHE_SAFE=0; CACHE_ID=dry-run; CACHE_KEY=dry-run; CACHE_DIR=$ARTIFACTS/$_ci_name/dry-run
    return 0
  fi
  _ci_tmp=${TMPDIR:-/tmp}/lwjgl-cache-id-$$
  _ci_n=0
  while ! mkdir "$_ci_tmp.$_ci_n" 2>/dev/null; do
    _ci_n=$((_ci_n + 1))
    [ "$_ci_n" -lt 100 ] || { CACHE_SAFE=0; break; }
  done
  _ci_tmp=$_ci_tmp.$_ci_n
  [ -d "$_ci_tmp" ] || { CACHE_SAFE=0; _ci_tmp=${TMPDIR:-/tmp}/lwjgl-cache-id-failed-$$; }
  _ci_commit=$(git -C "$_ci_src" rev-parse HEAD 2>/dev/null) || { _ci_commit=unknown; CACHE_SAFE=0; }
  _ci_tree=
  if [ "$_ci_commit" != unknown ]; then
    if git -C "$_ci_src" diff --binary HEAD > "$_ci_tmp.diff" 2>/dev/null; then
      cache_checksum "$_ci_tmp.diff" || { CACHE_SAFE=0; CACHE_SUM=unknown; }
      _ci_tree="diff=$CACHE_SUM"
    else
      CACHE_SAFE=0; _ci_tree=diff=unknown
    fi
    for _ci_mode in --exclude-standard --ignored; do
      _ci_tag=$(printf '%s' "$_ci_mode" | tr -d '-')
      if [ "$_ci_mode" = --ignored ]; then _ci_list_args="--ignored --exclude-standard"; else _ci_list_args=$_ci_mode; fi
      if git -C "$_ci_src" ls-files --others $_ci_list_args > "$_ci_tmp.files" 2>/dev/null; then
        _ci_list=
        while IFS= read -r _ci_file; do
          [ -n "$_ci_file" ] || continue
          case $_ci_file in *'|'*|*';'*) CACHE_SAFE=0; continue ;; esac
          case "$_ci_file" in
            "$_ci_exclude"|"$_ci_exclude"/*) [ -n "$_ci_exclude" ] && continue ;;
          esac
          [ ! -L "$_ci_src/$_ci_file" ] && [ -f "$_ci_src/$_ci_file" ] || { CACHE_SAFE=0; continue; }
          cache_checksum "$_ci_src/$_ci_file" || { CACHE_SAFE=0; continue; }
          _ci_list="$_ci_list|$_ci_file=$CACHE_SUM"
        done < "$_ci_tmp.files"
        _ci_tree="$_ci_tree;${_ci_tag}=$_ci_list"
      else
        CACHE_SAFE=0; _ci_tree="$_ci_tree;${_ci_tag}=unknown"
      fi
    done
    _ci_submodules=$(git -C "$_ci_src" submodule status 2>/dev/null) || { CACHE_SAFE=0; _ci_submodules=unknown; }
    _ci_tree="$_ci_tree;submodules=$_ci_submodules"
  else
    _ci_tree=unknown
  fi
  cache_tool_fingerprint "$CC"; _ci_cc_path=$CACHE_TOOL_FINGERPRINT
  cache_tool_version "$(command -v "$CC" 2>/dev/null || printf '%s' "$CC")" --version; _ci_cc=$CACHE_TOOL_VERSION
  cache_tool_fingerprint "$CXX"; _ci_cxx_path=$CACHE_TOOL_FINGERPRINT
  cache_tool_version "$(command -v "$CXX" 2>/dev/null || printf '%s' "$CXX")" --version; _ci_cxx=$CACHE_TOOL_VERSION
  cache_tool_fingerprint "$MAKE"; _ci_make_path=$CACHE_TOOL_FINGERPRINT
  cache_tool_version "$(command -v "$MAKE" 2>/dev/null || printf '%s' "$MAKE")" --version; _ci_make=$CACHE_TOOL_VERSION
  cache_tool_fingerprint "$CMAKE"; _ci_cmake_path=$CACHE_TOOL_FINGERPRINT
  cache_tool_version "$(command -v "$CMAKE" 2>/dev/null || printf '%s' "$CMAKE")" --version; _ci_cmake=$CACHE_TOOL_VERSION
  _ci_ant=$(command -v ant 2>/dev/null || true)
  if [ -n "$_ci_ant" ]; then
    cache_tool_fingerprint ant; _ci_ant_path=$CACHE_TOOL_FINGERPRINT
    cache_tool_version "$_ci_ant" -version; _ci_ant="$_ci_ant_path:$CACHE_TOOL_VERSION"
  else _ci_ant=unknown; fi
  _ci_tools="CC=$_ci_cc_path:$_ci_cc;CXX=$_ci_cxx_path:$_ci_cxx;MAKE=$_ci_make_path:$_ci_make;CMAKE=$_ci_cmake_path:$_ci_cmake;ANT=$_ci_ant"
  _ci_java=${JAVA_HOME:-unknown}
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    cache_checksum "$JAVA_HOME/bin/java" || { CACHE_SAFE=0; CACHE_SUM=unknown; }
    _ci_java="$JAVA_HOME/bin/java:$CACHE_SUM"
    cache_tool_version "$JAVA_HOME/bin/java" -version
    _ci_java="$_ci_java:$CACHE_TOOL_VERSION"
  elif [ -n "${JAVA_HOME:-}" ]; then
    CACHE_SAFE=0
  fi
  _ci_patches=
  _ci_dep_env="CPPFLAGS=${CPPFLAGS:-};CPATH=${CPATH:-};C_INCLUDE_PATH=${C_INCLUDE_PATH:-};CPLUS_INCLUDE_PATH=${CPLUS_INCLUDE_PATH:-};LIBRARY_PATH=${LIBRARY_PATH:-};SDKROOT=${SDKROOT:-};SYSROOT=${SYSROOT:-};CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH:-};CMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE:-};PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-};PKG_CONFIG_LIBDIR=${PKG_CONFIG_LIBDIR:-};PATH=${PATH:-}"
  if [ -d "$_ci_patchdir" ]; then
    for _ci_patch in "$_ci_patchdir"/*.patch; do
      [ -f "$_ci_patch" ] || continue
      cache_checksum "$_ci_patch" || die "cannot checksum $_ci_patch"
      _ci_base=$(basename "$_ci_patch")
      cache_valid_name "$_ci_base" || die "patch name is not canonical: $_ci_base"
      _ci_patches="$_ci_patches;$_ci_base=$CACHE_SUM"
    done
  fi
  [ -n "$_ci_patches" ] || _ci_patches=none
  CACHE_ID=$(printf 'format=4\ncomponent=%s\ncommit=%s\ntree=%s\npatches=%s\nplatform=%s\nhost=%s\nexpect_machine=%s\narch=%s\nCC=%s\nCXX=%s\nCFLAGS=%s\nCXXFLAGS=%s\nLDFLAGS=%s\nDEPS=%s\nTOOLS=%s\nJAVA=%s\nJOBS=%s\nextra=%s\n' \
    "$_ci_name" "$_ci_commit" "$_ci_tree" "$_ci_patches" "$(uname -s 2>/dev/null || printf unknown)" \
    "$(uname -m 2>/dev/null || printf unknown)" "${EXPECT_MACHINE:-002b}" "${ARCH_FLAGS:-}" "$CC:$_ci_cc" "$CXX:$_ci_cxx" "${CFLAGS:-}" "${CXXFLAGS:-}" "${LDFLAGS:-}" "$_ci_dep_env" \
    "$_ci_tools" "$_ci_java" "${JOBS:-}" "$_ci_extra")
  _ci_env_values=${CC}${CXX}${CFLAGS:-}${CXXFLAGS:-}${LDFLAGS:-}${CPPFLAGS:-}${CPATH:-}${C_INCLUDE_PATH:-}${CPLUS_INCLUDE_PATH:-}${LIBRARY_PATH:-}${SDKROOT:-}${SYSROOT:-}${CMAKE_PREFIX_PATH:-}${CMAKE_TOOLCHAIN_FILE:-}${PKG_CONFIG_PATH:-}${PKG_CONFIG_LIBDIR:-}${PATH:-}${_ci_cc_path}${_ci_cxx_path}${_ci_make_path}${_ci_cmake_path}${_ci_ant}${_ci_java}
  case "$_ci_env_values" in *'|'*|*';'*) CACHE_SAFE=0 ;; esac
  _ci_nl=$(printf '\nx'); _ci_nl=${_ci_nl%x}
  _ci_cr=$(printf '\rx'); _ci_cr=${_ci_cr%x}
  case "$_ci_extra" in *"$_ci_nl"*|*"$_ci_cr"*|*'|'*) CACHE_SAFE=0 ;; esac
  case "${CC}${CXX}${CFLAGS:-}${CXXFLAGS:-}${LDFLAGS:-}${CPPFLAGS:-}${CPATH:-}${C_INCLUDE_PATH:-}${CPLUS_INCLUDE_PATH:-}${LIBRARY_PATH:-}${SDKROOT:-}${SYSROOT:-}${CMAKE_PREFIX_PATH:-}${CMAKE_TOOLCHAIN_FILE:-}${PKG_CONFIG_PATH:-}${PKG_CONFIG_LIBDIR:-}${PATH:-}" in *'|'*|*';'*) CACHE_SAFE=0 ;; esac
  rm -rf "$_ci_tmp" "$_ci_tmp.diff" "$_ci_tmp.files"
  cache_digest "$CACHE_ID" || die "cannot checksum cache identity"
  CACHE_KEY=$CACHE_DIGEST
  CACHE_DIR=$ARTIFACTS/$_ci_name/$CACHE_KEY
}

# cache_entry_valid DIR ID OUTPUT... -- require metadata, checksum and ELF validity.
cache_entry_valid() {
  _ce_dir=$1; _ce_id=$2; shift 2
  [ "$#" -gt 0 ] || return 1
  [ ! -L "$_ce_dir" ] && [ -d "$_ce_dir" ] || return 1
  [ ! -L "$_ce_dir/complete" ] && [ -f "$_ce_dir/complete" ] || return 1
  [ ! -L "$_ce_dir/identity" ] && [ -f "$_ce_dir/identity" ] || return 1
  [ ! -L "$_ce_dir/files.manifest" ] && [ -f "$_ce_dir/files.manifest" ] || return 1
  [ ! -L "$_ce_dir/files" ] && [ -d "$_ce_dir/files" ] || return 1
  printf '%s' "$_ce_id" | cmp -s - "$_ce_dir/identity" || return 1
  _ce_expected=' '
  for _ce_file in "$@"; do
    cache_valid_name "$_ce_file" || return 1
    case $_ce_expected in *" $_ce_file "*) return 1 ;; esac
    _ce_expected="$_ce_expected$_ce_file "
    [ ! -L "$_ce_dir/files/$_ce_file" ] && [ -f "$_ce_dir/files/$_ce_file" ] || return 1
    cache_checksum "$_ce_dir/files/$_ce_file" || return 1
    _ce_count=$(grep -F -x -c "$_ce_file $CACHE_SUM" "$_ce_dir/files.manifest" 2>/dev/null || true)
    [ "${_ce_count:-0}" -eq 1 ] || return 1
    case $_ce_file in
      *.so|*.so.*)
        elf_check "$_ce_dir/files/$_ce_file" || return 1
        [ "$_ce_file" != libjemalloc.so ] || jemalloc_symbols_check "$_ce_dir/files/$_ce_file" || return 1
        ;;
    esac
  done
  _ce_manifest_count=$(wc -l < "$_ce_dir/files.manifest" | tr -d ' ')
  [ "$_ce_manifest_count" -eq "$#" ] || return 1
  _ce_payload_count=$(find "$_ce_dir/files" -type f -print | wc -l | tr -d ' ')
  _ce_dir_count=$(find "$_ce_dir/files" -type d -print | wc -l | tr -d ' ')
  _ce_other_count=$(find "$_ce_dir/files" ! -type f ! -type d -print | wc -l | tr -d ' ')
  [ "$_ce_payload_count" -eq "$#" ] && [ "$_ce_dir_count" -eq 1 ] && [ "$_ce_other_count" -eq 0 ] || return 1
  _ce_seen=' '
  _ce_lines=0
  while IFS= read -r _ce_line || [ -n "$_ce_line" ]; do
    [ -n "$_ce_line" ] || return 1
    _ce_name=${_ce_line%% *}
    [ "$_ce_name" != "$_ce_line" ] || return 1
    _ce_rest=${_ce_line#* }
    case $_ce_rest in *' '*) ;; *) return 1 ;; esac
    case $_ce_rest in *'
'*) return 1 ;; esac
    _ce_sum=${_ce_rest%% *}
    _ce_size=${_ce_rest#* }
    case "$_ce_sum" in ''|*[!0-9]*) return 1 ;; esac
    case "$_ce_size" in ''|*[!0-9]*) return 1 ;; esac
    case $_ce_size in *' '*) return 1 ;; esac
    case $_ce_seen in *" $_ce_name "*) return 1 ;; esac
    cache_valid_name "$_ce_name" || return 1
    case $_ce_expected in *" $_ce_name "*) : ;; *) return 1 ;; esac
    _ce_seen="$_ce_seen$_ce_name "
    _ce_lines=$((_ce_lines + 1))
  done < "$_ce_dir/files.manifest"
  [ "$_ce_lines" -eq "$#" ] || return 1
  return 0
}

# cache_restore NAME OUTPUT... -- validate and copy a complete entry into OUT.
# CACHE_KEY/CACHE_ID are set by cache_identity. CACHE_HIT is 1 on a hit.
cache_restore() {
  _cr_name=$1; shift
  CACHE_HIT=0
  is_dry && return 0
  [ "${CACHE_SAFE:-0}" -eq 1 ] || return 0
  [ "$#" -gt 0 ] || return 0
  cache_entry_valid "$CACHE_DIR" "$CACHE_ID" "$@" || {
    [ -d "$CACHE_DIR" ] && warn "rejecting incomplete or invalid cache entry $_cr_name ($CACHE_KEY)"
    return 0
  }
  mkdir -p "$OUT" || return 1
  _cr_n=$$
  _cr_tmp=$OUT/.cache-restore-$_cr_n
  _cr_backup=$OUT/.cache-backup-$_cr_n
  while [ -e "$_cr_tmp" ] || [ -L "$_cr_tmp" ] || [ -e "$_cr_backup" ] || [ -L "$_cr_backup" ]; do
    _cr_n=$((_cr_n + 1)); _cr_tmp=$OUT/.cache-restore-$_cr_n; _cr_backup=$OUT/.cache-backup-$_cr_n
  done
  mkdir "$_cr_tmp" "$_cr_backup" || { rm -rf "$_cr_tmp" "$_cr_backup"; return 1; }
  for _cr_file in "$@"; do
    cp "$CACHE_DIR/files/$_cr_file" "$_cr_tmp/$_cr_file" || { rm -rf "$_cr_tmp" "$_cr_backup"; return 1; }
  done
  _cr_backed=
  _cr_installed=
  for _cr_file in "$@"; do
    if [ -e "$OUT/$_cr_file" ] || [ -L "$OUT/$_cr_file" ]; then
      if ! mv "$OUT/$_cr_file" "$_cr_backup/$_cr_file"; then
        _cr_rollback_failed=0
        for _cr_done in $_cr_backed; do
          mv "$_cr_backup/$_cr_done" "$OUT/$_cr_done" 2>/dev/null || _cr_rollback_failed=1
        done
        rm -rf "$_cr_tmp"
        if [ "$_cr_rollback_failed" -eq 0 ]; then rm -rf "$_cr_backup"; else warn "restore rollback incomplete; recovery files remain in $_cr_backup"; fi
        return 1
      fi
      _cr_backed="$_cr_backed $_cr_file"
    fi
  done
  for _cr_file in "$@"; do
    if ! mv "$_cr_tmp/$_cr_file" "$OUT/$_cr_file"; then
      _cr_rollback_failed=0
      for _cr_done in $_cr_installed; do rm -f "$OUT/$_cr_done" || _cr_rollback_failed=1; done
      for _cr_done in $_cr_backed; do mv "$_cr_backup/$_cr_done" "$OUT/$_cr_done" 2>/dev/null || _cr_rollback_failed=1; done
      rm -rf "$_cr_tmp"
      if [ "$_cr_rollback_failed" -eq 0 ]; then rm -rf "$_cr_backup"; else warn "restore rollback incomplete; recovery files remain in $_cr_backup"; fi
      return 1
    fi
    _cr_installed="$_cr_installed $_cr_file"
  done
  rm -rf "$_cr_tmp" "$_cr_backup"
  CACHE_HIT=1
  log "cache hit: $_cr_name ($CACHE_KEY)"
}

# cache_publish NAME SOURCE_DIR FILE... -- publish a complete cache entry.
# Entry visibility is atomic; flat output restore is rollback-oriented, not atomic.
cache_lock_release() {
  [ "$(cat "$1/owner" 2>/dev/null || true)" = "$2" ] || return 0
  rm -f "$1/owner"
  rmdir "$1" 2>/dev/null || warn "could not release cache lock: $1"
}

cache_publish() {
  _cp_name=$1; _cp_src=$2; shift 2
  is_dry && return 0
  [ "${CACHE_SAFE:-0}" -eq 1 ] || return 0
  cache_valid_name "$_cp_name" || return 1
  [ "$#" -gt 0 ] || return 1
  for _cp_file in "$@"; do cache_valid_name "$_cp_file" || return 1; done
  _cp_parent=$ARTIFACTS/$_cp_name
  mkdir -p "$_cp_parent" || return 1
  _cp_lock=$_cp_parent/.$CACHE_KEY.lock
  _cp_n=$$
  _cp_tmp=$_cp_parent/.$CACHE_KEY.$_cp_n
  while [ -e "$_cp_tmp" ] || [ -L "$_cp_tmp" ]; do _cp_n=$((_cp_n + 1)); _cp_tmp=$_cp_parent/.$CACHE_KEY.$_cp_n; done
  mkdir "$_cp_tmp" || return 1
  mkdir "$_cp_tmp/files" || { rm -rf "$_cp_tmp"; return 1; }
  : > "$_cp_tmp/files.manifest" || { rm -rf "$_cp_tmp"; return 1; }
  for _cp_file in "$@"; do
    [ ! -L "$_cp_src/$_cp_file" ] && [ -f "$_cp_src/$_cp_file" ] || { rm -rf "$_cp_tmp"; return 1; }
    case $_cp_file in *.so|*.so.*)
      elf_check "$_cp_src/$_cp_file" || { rm -rf "$_cp_tmp"; warn "not caching invalid SPARCV9 native $_cp_src/$_cp_file"; return 1; }
      [ "$_cp_file" != libjemalloc.so ] || jemalloc_symbols_check "$_cp_src/$_cp_file" || { rm -rf "$_cp_tmp"; warn "not caching jemalloc without LWJGL sized-free symbols: $_cp_src/$_cp_file"; return 1; } ;;
    esac
    cp "$_cp_src/$_cp_file" "$_cp_tmp/files/$_cp_file" || { rm -rf "$_cp_tmp"; return 1; }
    cache_checksum "$_cp_tmp/files/$_cp_file" || { rm -rf "$_cp_tmp"; return 1; }
    printf '%s %s\n' "$_cp_file" "$CACHE_SUM" >> "$_cp_tmp/files.manifest" || { rm -rf "$_cp_tmp"; return 1; }
  done
  printf '%s' "$CACHE_ID" > "$_cp_tmp/identity" || { rm -rf "$_cp_tmp"; return 1; }
  : > "$_cp_tmp/complete" || { rm -rf "$_cp_tmp"; return 1; }
  cache_entry_valid "$_cp_tmp" "$CACHE_ID" "$@" || { rm -rf "$_cp_tmp"; return 1; }
  _cp_host=$(uname -n 2>/dev/null || printf unknown)
  _cp_now=$(date +%s 2>/dev/null || printf 0)
  case $_cp_now in ''|*[!0-9]*) _cp_now=0 ;; esac
  _cp_owner_line="$$ $_cp_host $_cp_now"
  _cp_attempt=0
  while ! mkdir "$_cp_lock" 2>/dev/null; do
    if [ ! -d "$_cp_lock" ] || [ -L "$_cp_lock" ]; then
      rm -rf "$_cp_tmp"
      warn "cannot acquire cache publisher lock: $_cp_lock"
      return 1
    fi
    _cp_owner=$(cat "$_cp_lock/owner" 2>/dev/null || true)
    _cp_owner_pid=${_cp_owner%% *}
    _cp_owner_rest=${_cp_owner#* }
    _cp_owner_host=${_cp_owner_rest%% *}
    _cp_owner_epoch=${_cp_owner_rest#* }
    _cp_is_stale=0
    case "$_cp_owner_pid" in ''|*[!0-9]*)
      _cp_grace=${CACHE_LOCK_GRACE_SECONDS:-5}
      case $_cp_grace in ''|*[!0-9]*) _cp_grace=5 ;; esac
      _cp_wait=0
      while [ "$_cp_wait" -lt "$_cp_grace" ] && [ -d "$_cp_lock" ]; do
        sleep 1
        _cp_wait=$((_cp_wait + 1))
        _cp_owner=$(cat "$_cp_lock/owner" 2>/dev/null || true)
        _cp_owner_pid=${_cp_owner%% *}
        _cp_owner_rest=${_cp_owner#* }
        _cp_owner_host=${_cp_owner_rest%% *}
        _cp_owner_epoch=${_cp_owner_rest#* }
        case $_cp_owner_pid in ''|*[!0-9]*) ;; *) break ;; esac
      done
      case $_cp_owner_pid in ''|*[!0-9]*) _cp_is_stale=1 ;; esac ;;
    *)
      if [ "$_cp_owner_host" = "$_cp_host" ] && ! kill -0 "$_cp_owner_pid" 2>/dev/null; then
        _cp_is_stale=1
      fi ;;
    esac
    case $_cp_owner_epoch in ''|*[!0-9]*) ;; *)
      _cp_now=$(date +%s 2>/dev/null || printf 0)
      case $_cp_now in ''|*[!0-9]*) _cp_now=0 ;; esac
      _cp_age_limit=${CACHE_LOCK_STALE_SECONDS:-600}
      case $_cp_age_limit in ''|*[!0-9]*) _cp_age_limit=600 ;; esac
      if [ "$_cp_now" -gt 0 ] && [ "$_cp_owner_epoch" -gt 0 ] &&
         [ "$_cp_now" -gt "$_cp_owner_epoch" ] &&
         [ $((_cp_now - _cp_owner_epoch)) -gt "$_cp_age_limit" ]; then
        _cp_is_stale=1
      fi ;;
    esac
    if [ "$_cp_is_stale" -eq 1 ]; then
      _cp_stale=$_cp_lock.stale.$$
      _cp_n=0
      while [ -e "$_cp_stale" ] || [ -L "$_cp_stale" ]; do
        _cp_n=$((_cp_n + 1)); _cp_stale=$_cp_lock.stale.$$.$_cp_n
        [ "$_cp_n" -lt 100 ] || break
      done
      if [ "$_cp_n" -lt 100 ] && mv "$_cp_lock" "$_cp_stale" 2>/dev/null; then
        rm -rf "$_cp_stale"
        _cp_attempt=$((_cp_attempt + 1))
        [ "$_cp_attempt" -lt 3 ] && continue
      fi
    fi
    rm -rf "$_cp_tmp"
    warn "cache publisher lock is held or cannot be safely recovered; skipping publication: $_cp_lock"
    return 0
  done
  _cp_now=$(date +%s 2>/dev/null || printf 0)
  case $_cp_now in ''|*[!0-9]*) _cp_now=0 ;; esac
  if ! printf '%s\n' "$_cp_owner_line" > "$_cp_lock/owner"; then
    rmdir "$_cp_lock" 2>/dev/null || true
    rm -rf "$_cp_tmp"
    warn "cannot record cache publisher lock owner: $_cp_lock"
    return 1
  fi
  _cp_invalid=
  if [ -e "$CACHE_DIR" ] || [ -L "$CACHE_DIR" ]; then
    if cache_entry_valid "$CACHE_DIR" "$CACHE_ID" "$@"; then
      rm -rf "$_cp_tmp"
      cache_lock_release "$_cp_lock" "$_cp_owner_line"
      return 0
    fi
    _cp_invalid=$_cp_parent/.$CACHE_KEY.invalid.$$
    _cp_n=0
    while [ -e "$_cp_invalid" ] || [ -L "$_cp_invalid" ]; do
      _cp_n=$((_cp_n + 1)); _cp_invalid=$_cp_parent/.$CACHE_KEY.invalid.$$.$_cp_n
      [ "$_cp_n" -lt 100 ] || break
    done
    if [ "$_cp_n" -ge 100 ] || ! mv "$CACHE_DIR" "$_cp_invalid" 2>/dev/null; then
      rm -rf "$_cp_tmp"
      cache_lock_release "$_cp_lock" "$_cp_owner_line"
      warn "cannot quarantine invalid cache key: $CACHE_DIR"
      return 1
    fi
    warn "quarantined invalid cache entry: $_cp_invalid"
  fi
  if ! mkdir "$CACHE_DIR" 2>/dev/null; then
    if cache_entry_valid "$CACHE_DIR" "$CACHE_ID" "$@"; then
      rm -rf "$_cp_tmp"
      cache_lock_release "$_cp_lock" "$_cp_owner_line"
      return 0
    fi
    rm -rf "$_cp_tmp"
    cache_lock_release "$_cp_lock" "$_cp_owner_line"
    warn "cannot claim cache entry directory: $CACHE_DIR"
    return 1
  fi
  if ! mv "$_cp_tmp/identity" "$CACHE_DIR/identity" ||
     ! mv "$_cp_tmp/files.manifest" "$CACHE_DIR/files.manifest" ||
     ! mv "$_cp_tmp/files" "$CACHE_DIR/files" ||
     ! : > "$CACHE_DIR/complete"; then
    rm -rf "$CACHE_DIR" "$_cp_tmp"
    cache_lock_release "$_cp_lock" "$_cp_owner_line"
    return 1
  fi
  rmdir "$_cp_tmp" 2>/dev/null || rm -rf "$_cp_tmp"
  [ -z "${_cp_invalid:-}" ] || rm -rf "$_cp_invalid"
  cache_lock_release "$_cp_lock" "$_cp_owner_line"
  log "cached: $_cp_name ($CACHE_KEY)"
}

# elf_read_header FILE -- set ELF_HEADER to 20 validated hex-byte tokens.
elf_read_header() {
  _er_od=${ELF_OD:-od}
  _er_output=$("$_er_od" -A n -v -t x1 -N 20 "$1" 2>/dev/null) || {
    ELF_HEADER_ERROR="od failed while reading $1"
    return 1
  }
  # Use xargs to normalize whitespace (handles tabs, newlines, multiple spaces)
  _er_header=$(printf '%s\n' "$_er_output" | tr 'A-F' 'a-f' | xargs printf '%s ' 2>/dev/null)
  _er_header=${_er_header% }
  set -- $_er_header
  [ "$#" -eq 20 ] || { ELF_HEADER_ERROR="expected 20 bytes from od, got $#"; return 1; }
  for _er_byte do
    case $_er_byte in ??) ;; *) ELF_HEADER_ERROR="invalid byte from od: $_er_byte"; return 1 ;; esac
    case $_er_byte in *[!0-9a-f]*) ELF_HEADER_ERROR="invalid byte from od: $_er_byte"; return 1 ;; esac
  done
  ELF_HEADER="$(printf '%s' "$_er_header" | tr -d ' ' | tr '\t' '')"
  ELF_HEADER_ERROR=
}

# elf_header FILE -> prints the measured ELF class, byte order and machine.
elf_header() {
  elf_read_header "$1" || { printf 'unreadable ELF header (%s)' "$ELF_HEADER_ERROR"; return 1; }
  _eh=$ELF_HEADER
  _emagic=$(printf '%s' "$_eh" | cut -c1-8)
  [ "$_emagic" = 7f454c46 ] || { printf 'not-ELF'; return 1; }
  _eclass=$(printf '%s' "$_eh" | cut -c9-10)
  _edata=$(printf '%s' "$_eh" | cut -c11-12)
  _emach=$(printf '%s' "$_eh" | cut -c37-40)
  case $_eclass in 01) _eclass_name=32-bit ;; 02) _eclass_name=64-bit ;; *) _eclass_name="class-0x$_eclass" ;; esac
  case $_edata in 01) _edata_name=LSB ;; 02) _edata_name=MSB ;; *) _edata_name="data-0x$_edata" ;; esac
  printf '%s %s e_machine=0x%s' "$_eclass_name" "$_edata_name" "$_emach"
}

# elf_check FILE -> 0 when FILE is a 64-bit big-endian SPARCV9 ELF object
elf_check() {
  elf_read_header "$1" || return 1
  _h=$ELF_HEADER
  _magic=$(printf '%s' "$_h" | cut -c1-8)
  _class=$(printf '%s' "$_h" | cut -c9-10)
  _data=$(printf '%s' "$_h" | cut -c11-12)
  _mach=$(printf '%s' "$_h" | cut -c37-40)
  [ "$_magic" = 7f454c46 ] && [ "$_class" = 02 ] && [ "$_data" = 02 ] &&
    [ "$_mach" = "${EXPECT_MACHINE:-002b}" ]
}

# jemalloc_symbols_text_check TEXT -- require version-specific LWJGL exports.
jemalloc_symbols_text_check() {
  _jt_symbols=$1
  for _jt_symbol in ${JEMALLOC_REQUIRED_SYMBOLS:-}; do
    printf '%s\n' "$_jt_symbols" | awk -v symbol="$_jt_symbol" '$NF == symbol { found=1 } END { exit !found }' || return 1
  done
}

# jemalloc_symbols_check FILE -- inspect dynamic exports using Solaris or GNU tools.
jemalloc_symbols_check() {
  _js_file=$1
  if [ -z "${JEMALLOC_REQUIRED_SYMBOLS:-}" ]; then
    case "${LWJGL_VERSION:-}" in 3.4.3*) JEMALLOC_REQUIRED_SYMBOLS='je_free_sized je_free_aligned_sized' ;; esac
  fi
  [ -n "${JEMALLOC_REQUIRED_SYMBOLS:-}" ] || return 0
  if [ -n "${DRY_RUN:-}" ]; then return 0; fi
  _js_elfdump=$(command -v elfdump 2>/dev/null || true)
  if [ -n "$_js_elfdump" ]; then
    _js_symbols=$($_js_elfdump -s "$_js_file" 2>/dev/null) || return 1
  else
    _js_nm=$(command -v nm 2>/dev/null || true)
    [ -n "$_js_nm" ] || return 1
    _js_symbols=$($_js_nm -D "$_js_file" 2>/dev/null) || return 1
  fi
  jemalloc_symbols_text_check "$_js_symbols"
}

verify_natives() {
  is_dry && { printf '+ verify %s in %s\n' "$NATIVES" "$OUT" >&2; return 0; }
  _bad=0
  for _f in $NATIVES; do
    if [ ! -f "$OUT/$_f" ]; then
      printf 'MISSING  %s\n' "$_f" >&2; _bad=$((_bad + 1))
    elif ! elf_check "$OUT/$_f"; then
      _actual=$(elf_header "$OUT/$_f" 2>/dev/null || true)
      printf 'WRONG-ELF %s (got %s; want 64-bit MSB, e_machine 0x%s)\n' \
        "$_f" "${_actual:-unreadable ELF header}" "${EXPECT_MACHINE:-002b}" >&2
      _bad=$((_bad + 1))
    elif [ "$_f" = libjemalloc.so ] && ! jemalloc_symbols_check "$OUT/$_f"; then
      printf 'MISSING-SYMBOL %s (need je_free_sized and je_free_aligned_sized)\n' "$_f" >&2
      _bad=$((_bad + 1))
    else
      printf 'ok       %s\n' "$_f" >&2
    fi
  done
  [ "$_bad" -eq 0 ] || die "$_bad native(s) missing or not SPARCV9 in $OUT"
  log "all $(printf '%s\n' $NATIVES | wc -l | tr -d ' ') natives present for Minecraft $MC_VERSION"
}
