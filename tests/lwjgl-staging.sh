#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/common.sh"
. "$ROOT/lib/components.sh"

TMP=${TMPDIR:-/tmp}/lwjgl-staging-test-$$
trap 'rm -rf "$TMP"' 0 HUP INT TERM
SRC=$TMP/src
OUT=$TMP/out
WORK=$TMP/work
mkdir -p "$SRC/bin/classes/lwjgl/core" \
         "$SRC/bin/classes/lwjgl/openal" \
         "$SRC/bin/classes/lwjgl/opengl" \
         "$SRC/bin/classes/lwjgl/opengles" \
         "$SRC/bin/classes/lwjgl/vulkan" \
         "$SRC/bin/classes/alternate/org/lwjgl/vulkan" \
         "$TMP/java/bin"

# Use a tiny jar-tool double so this portable test does not depend on the host
# JDK. It records the paths passed to create/update operations as jar entries.
cat > "$TMP/java/bin/jar" <<'EOF'
#!/bin/sh
set -eu
mode=$1
archive=$2
shift 2
case "$mode" in
  cf) : > "$archive" ;;
  uf) ;;
  *) exit 2 ;;
esac
root=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) root=$2; shift 2 ;;
    .)
      find "$root" -type f -print | while IFS= read -r path; do
        path=${path#"$root"/}
        printf '%s\n' "$path" >> "$archive"
      done
      shift ;;
    *)
      # Solaris jar scopes -C to one following file. Validate the source
      # path so a multi-file invocation regresses instead of masking this.
      [ -f "$root/$1" ] || exit 1
      printf '%s\n' "$1" >> "$archive"
      root=.
      shift
      ;;
  esac
done
EOF
chmod +x "$TMP/java/bin/jar"

# The contents are irrelevant; the jar layout and source-root selection are not.
for _class in \
  org/lwjgl/system/Platform.class \
  org/lwjgl/openal/ALC.class \
  org/lwjgl/openal/ALC\$1.class \
  org/lwjgl/opengl/GL.class \
  org/lwjgl/opengles/GLES.class \
  org/lwjgl/vulkan/VK.class \
  org/lwjgl/vulkan/VK\$1.class \
  org/lwjgl/vulkan/VKCapabilities.class; do
  case "$_class" in
    org/lwjgl/system/*) _root="$SRC/bin/classes/lwjgl/core" ;;
    org/lwjgl/openal/*) _root="$SRC/bin/classes/lwjgl/openal" ;;
    org/lwjgl/opengl/*) _root="$SRC/bin/classes/lwjgl/opengl" ;;
    org/lwjgl/opengles/*) _root="$SRC/bin/classes/lwjgl/opengles" ;;
    *) _root="$SRC/bin/classes/lwjgl/vulkan" ;;
  esac
  mkdir -p "$_root/$(dirname "$_class")"
  printf '%s\n' "$_class" > "$_root/$_class"
done

# A competing lower-priority root must not win over the module-specific root.
printf 'wrong root\n' > "$SRC/bin/classes/alternate/org/lwjgl/vulkan/VK.class"

OUT=$OUT WORK=$WORK JAVA_HOME=$TMP/java lwjgl_core_jar "$SRC"
JAR=${OUT}/lwjgl.jar
[ -f "$JAR" ] || die 'staging did not produce lwjgl.jar'

_has() { grep -Fx "$1" "$JAR" >/dev/null || die "jar lacks $1"; }
_has org/lwjgl/system/Platform.class
_has org/lwjgl/openal/ALC.class
_has 'org/lwjgl/openal/ALC$1.class'
_has org/lwjgl/opengl/GL.class
_has org/lwjgl/opengles/GLES.class
_has org/lwjgl/vulkan/VK.class
_has 'org/lwjgl/vulkan/VK$1.class'
if grep -Fx org/lwjgl/vulkan/VKCapabilities.class "$JAR" >/dev/null; then
  die 'unrelated Vulkan class was staged'
fi

# A missing required primary must fail instead of falling back to stock module code.
rm -f "$SRC/bin/classes/lwjgl/openal/org/lwjgl/openal/ALC.class"
if ( OUT="$TMP/missing-out" WORK="$WORK" JAVA_HOME=$TMP/java \
    lwjgl_core_jar "$SRC" >/dev/null 2>&1 ); then
  die 'missing patched ALC.class was accepted'
fi

printf 'lwjgl staging tests: ok\n'
