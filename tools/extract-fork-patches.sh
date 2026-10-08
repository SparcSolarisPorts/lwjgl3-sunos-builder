#!/usr/xpg4/bin/sh
# Turn the Solaris commits of a fork (SparcSolarisPorts/lwjgl3, /glfw, /SDL)
# into per-release patch sets by replaying them onto each release's upstream
# tag. The forks track master, so older tags will conflict; every commit that
# does not replay cleanly is listed in SKIPPED.txt for manual porting.
#
#   tools/extract-fork-patches.sh COMPONENT FORK_CHECKOUT UPSTREAM_URL [MC ...]
#   e.g. tools/extract-fork-patches.sh lwjgl3 ~/git/lwjgl3 https://github.com/LWJGL/lwjgl3.git 1.20.1
#
# Output: mc/<MC>/patches/<COMPONENT>.generated/  (review, then move into
# patches/<COMPONENT>/ -- the builder only applies the non-.generated dir).
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
[ "$#" -ge 3 ] || { sed -n '2,12p' "$0" >&2; exit 2; }
COMP=$1; FORK=$2; UP=$3; shift 3
case "$COMP" in lwjgl3) REFVAR=LWJGL_REF ;; glfw) REFVAR=GLFW_REF ;; sdl3) REFVAR=SDL3_REF ;; *) echo "component: lwjgl3|glfw|sdl3" >&2; exit 2 ;; esac
[ -d "$FORK/.git" ] || { echo "not a git checkout: $FORK" >&2; exit 1; }
[ "$#" -gt 0 ] || set -- $(grep -v '^#' "$ROOT/versions.conf" | cut -d'|' -f1)

G="git -C $FORK"
$G remote get-url upstream >/dev/null 2>&1 || $G remote add upstream "$UP"
$G fetch -q --tags upstream
UPHEAD=$($G symbolic-ref -q --short refs/remotes/upstream/HEAD 2>/dev/null || true)
[ -n "$UPHEAD" ] || { $G rev-parse -q --verify upstream/master >/dev/null && UPHEAD=upstream/master || UPHEAD=upstream/main; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"; $G worktree prune' EXIT
SERIES=$TMP/series; mkdir -p "$SERIES"
# commits reachable from the fork but not from upstream = the Solaris work,
# even if upstream was merged into the fork several times
$G format-patch -q -k --no-stat --no-merges -o "$SERIES" "$UPHEAD..HEAD"
N=$(ls "$SERIES" | wc -l | tr -d ' ')
echo "fork carries $N non-merge commits not in $UPHEAD" >&2
[ "$N" -gt 0 ] || { echo "nothing to extract" >&2; exit 1; }

for mc in "$@"; do
  envf=$ROOT/mc/$mc/version.env
  [ -f "$envf" ] || { echo "skip $mc: no mc/$mc/version.env" >&2; continue; }
  ref=$(sh -c ". '$envf'; eval echo \"\${$REFVAR:-}\"") 
  [ -n "$ref" ] || { echo "skip $mc: no $REFVAR" >&2; continue; }
  WT=$TMP/wt-$mc
  $G worktree add -q --detach "$WT" "$ref" 2>/dev/null || { echo "skip $mc: tag $ref missing upstream" >&2; continue; }
  OUTD=$ROOT/mc/$mc/patches/$COMP.generated
  rm -rf "$OUTD"; mkdir -p "$OUTD"; : > "$OUTD/SKIPPED.txt"
  ok=0; skipped=0
  for p in "$SERIES"/*.patch; do
    if git -C "$WT" -c user.name=builder -c user.email=builder@localhost am -3 -q "$p" >/dev/null 2>&1; then
      ok=$((ok + 1))
    else
      git -C "$WT" am --abort >/dev/null 2>&1 || true
      skipped=$((skipped + 1))
      printf '%s\t%s\n' "$(basename "$p")" "$(sed -n 's/^Subject: //p' "$p" | head -1)" >> "$OUTD/SKIPPED.txt"
    fi
  done
  if [ "$ok" -gt 0 ]; then
    git -C "$WT" format-patch -q -k --no-stat -o "$OUTD" "$ref..HEAD"
  fi
  [ -s "$OUTD/SKIPPED.txt" ] || rm -f "$OUTD/SKIPPED.txt"
  echo "$mc ($ref): $ok replayed, $skipped need manual porting -> ${OUTD#$ROOT/}" >&2
  git -C "$WT" checkout -q --detach 2>/dev/null || true
  $G worktree remove --force "$WT" 2>/dev/null || true
done
