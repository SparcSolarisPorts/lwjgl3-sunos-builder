#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/common.sh"
TMP=${TMPDIR:-/tmp}/lwjgl-cache-test-$$
trap 'rm -rf "$TMP"' 0 HUP INT TERM
mkdir -p "$TMP/src" "$TMP/patches" "$TMP/artifacts" "$TMP/out1" "$TMP/out2" "$TMP/input"
CACHE=$TMP/source-cache ARTIFACTS=$TMP/artifacts WORK=$TMP/work
OUT=$TMP/out1 MC_VERSION=test
CC=cc CXX=c++ MAKE=make CMAKE=cmake JOBS=1
ARCH_FLAGS=-m64 CFLAGS= CXXFLAGS= LDFLAGS=
EXPECT_MACHINE=002b

# Minimal 64-bit big-endian SPARC ELF header (20-byte e_ident + e_type/e_machine).
elf_header_file() {
  printf '\177ELF\002\002\001\000\000\000\000\000\000\000\000\000\000\002\000\053' > "$1"
}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { "$@" || fail "$*"; }

elf_header_file "$TMP/input/libsample.so"
printf 'jar payload\n' > "$TMP/input/sample.jar"
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
KEY=$CACHE_KEY
cache_publish sample "$TMP/input" libsample.so sample.jar || fail 'publish failed'
[ -f "$CACHE_DIR/complete" ] || fail 'complete marker missing'

rm -f "$OUT/libsample.so" "$OUT/sample.jar"
cache_restore sample libsample.so sample.jar || fail 'restore failed'
[ "$CACHE_HIT" -eq 1 ] || fail 'expected cache hit'
cmp -s "$TMP/input/libsample.so" "$OUT/libsample.so" || fail 'native bytes differ'
cmp -s "$TMP/input/sample.jar" "$OUT/sample.jar" || fail 'jar bytes differ'

# Matching artifact is copied into a separate release-local output directory.
OUT=$TMP/out2
cache_restore sample libsample.so sample.jar || fail 'second restore failed'
[ "$CACHE_HIT" -eq 1 ] || fail 'expected cross-release cache hit'
[ -f "$TMP/out1/libsample.so" ] && [ -f "$TMP/out2/libsample.so" ] || fail 'outputs not staged separately'
cmp -s "$TMP/input/libsample.so" "$TMP/out2/libsample.so" || fail 'second release native differs'
cmp -s "$TMP/input/sample.jar" "$TMP/out2/sample.jar" || fail 'second release jar differs'

# Incomplete entries, wrong identity and corrupted payloads are misses.
rm -f "$CACHE_DIR/complete"
rm -f "$OUT/libsample.so" "$OUT/sample.jar"
cache_restore sample libsample.so sample.jar || fail 'incomplete restore errored'
[ "$CACHE_HIT" -eq 0 ] || fail 'incomplete entry accepted'
[ ! -e "$OUT/libsample.so" ] && [ ! -e "$OUT/sample.jar" ] || fail 'incomplete entry staged files'
: > "$CACHE_DIR/complete"
printf '%s\n' changed > "$CACHE_DIR/identity"
cache_restore sample libsample.so || fail 'identity mismatch restore errored'
[ "$CACHE_HIT" -eq 0 ] || fail 'identity mismatch accepted'
[ ! -e "$OUT/libsample.so" ] || fail 'identity-mismatched entry staged files'
printf '%s' "$CACHE_ID" > "$CACHE_DIR/identity"
printf 'corrupt' >> "$CACHE_DIR/files/sample.jar"
cache_restore sample sample.jar || fail 'corruption restore errored'
[ "$CACHE_HIT" -eq 0 ] || fail 'corrupted payload accepted'
[ ! -e "$OUT/sample.jar" ] || fail 'corrupted entry staged files'

# ELF validation rejects wrong class, byte order, and machine.
for _bad_elf in class endian machine; do
  case $_bad_elf in
    class) printf '\177ELF\001\002\001\000\000\000\000\000\000\000\000\000\000\002\000\053' > "$TMP/input/wrong.so" ;;
    endian) printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\000\002\053\000' > "$TMP/input/wrong.so" ;;
    machine) printf '\177ELF\002\002\001\000\000\000\000\000\000\000\000\000\000\002\000\003\000' > "$TMP/input/wrong.so" ;;
  esac
  if cache_publish "wrong-$_bad_elf" "$TMP/input" wrong.so 2>/dev/null; then fail "$_bad_elf ELF published"; fi
done

# Identity changes when recipe flags change.
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
KEY1=$CACHE_KEY
CFLAGS=-O3
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
[ "$CACHE_KEY" != "$KEY1" ] || fail 'CFLAGS did not invalidate identity'

printf 'cache tests: ok\n'
