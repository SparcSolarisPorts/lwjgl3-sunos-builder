#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/common.sh"
TMP=${TMPDIR:-/tmp}/lwjgl-cache-test-$$
trap 'rm -rf "$TMP"' 0 HUP INT TERM
mkdir -p "$TMP/src" "$TMP/patches" "$TMP/artifacts" "$TMP/out1" "$TMP/out2" "$TMP/input"
git -C "$TMP/src" init -q
git -C "$TMP/src" config user.email cache-test@example.invalid
git -C "$TMP/src" config user.name cache-test
printf 'source\n' > "$TMP/src/source.txt"
git -C "$TMP/src" add source.txt
git -C "$TMP/src" commit -qm initial
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

# The LWJGL 3.4.3 jemalloc binding requires both sized-free exports.
JEMALLOC_REQUIRED_SYMBOLS='je_free_sized je_free_aligned_sized'
JEMALLOC_SYMBOLS=$(printf 'Symbol Table Section: .dynsym\n  [1] 0x0000 0 FUNC GLOB 0 DEFAULT je_free_sized\n  [2] 0x0000 0 FUNC GLOB 0 DEFAULT je_free_aligned_sized')
jemalloc_symbols_text_check "$JEMALLOC_SYMBOLS" || fail 'required jemalloc symbols rejected'
if jemalloc_symbols_text_check "$(printf 'Symbol Table Section: .dynsym\n  [1] 0x0000 0 FUNC GLOB 0 DEFAULT je_free_sized')"; then
  fail 'incomplete jemalloc symbol set accepted'
fi

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

# Identity changes for ignored inputs and tool executable content/path.
mkdir -p "$TMP/src/.ignored"
printf 'first ignored payload\n' > "$TMP/src/.ignored/input"
git -C "$TMP/src" config core.excludesFile /dev/null
printf '.ignored/\n' > "$TMP/src/.gitignore"
git -C "$TMP/src" add .gitignore
# Commit the ignore rule so only its payload is an ignored working input.
git -C "$TMP/src" commit -qm ignore-rule
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
KEY1=$CACHE_KEY
printf 'changed ignored payload\n' > "$TMP/src/.ignored/input"
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
[ "$CACHE_KEY" != "$KEY1" ] || fail 'ignored input did not invalidate identity'
printf 'first ignored payload\n' > "$TMP/src/.ignored/input"

mkdir -p "$TMP/tool-a" "$TMP/tool-b"
for _tool_dir in "$TMP/tool-a" "$TMP/tool-b"; do
  printf '#!/bin/sh\nprintf "same version\\n"\n' > "$_tool_dir/cc"
  chmod +x "$_tool_dir/cc"
done
CC="$TMP/tool-a/cc"
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
KEY1=$CACHE_KEY
CC="$TMP/tool-b/cc"
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
[ "$CACHE_KEY" != "$KEY1" ] || fail 'tool path did not invalidate identity'
CC=cc

# Identity changes when recipe flags, patch names/content, or source tree change.
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
KEY1=$CACHE_KEY
CFLAGS=-O3
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
[ "$CACHE_KEY" != "$KEY1" ] || fail 'CFLAGS did not invalidate identity'
CFLAGS=
printf 'patch one\n' > "$TMP/patches/001.patch"
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
KEY1=$CACHE_KEY
mv "$TMP/patches/001.patch" "$TMP/patches/002.patch"
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
[ "$CACHE_KEY" != "$KEY1" ] || fail 'patch name did not invalidate identity'
printf 'dirty source\n' >> "$TMP/src/source.txt"
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
[ "$CACHE_KEY" != "$KEY1" ] || fail 'dirty source did not invalidate identity'

# Dry-run restore is a miss and must not create output files/directories.
OUT=$TMP/dry-out
DRY_RUN=1
cache_identity sample "$TMP/src" "$TMP/patches" 'recipe=one'
cache_restore sample sample.jar || fail 'dry-run restore errored'
[ "$CACHE_HIT" -eq 0 ] && [ ! -e "$OUT" ] || fail 'dry-run restore mutated output'
unset DRY_RUN

printf 'cache tests: ok\n'
