#!/usr/xpg4/bin/sh
# Scaffold mc/<MC>/ (version.env, build.sh, patches/) for a Minecraft release.
#   tools/new-version.sh MC LWJGL [--from mc/<existing>] [--regen]
#                        [--sdl3|--no-glfw|--no-tinyfd|--no-freetype|--vulkan]
# --from   copies that version's patches/ so you start from a known-good set.
# --regen  only rewrite version.env of an existing mc/<MC> (keeps patches).
# The native set is derived from the LWJGL version and the MC release, matching
# what Mojang's version JSONs ship (compare ~/.minecraft/versions/*/*.json):
#   glfw      every LWJGL except 3.4.3 (26.3+ uses SDL3)
#   tinyfd    1.15 .. 26.2   (not in 1.13/1.14 and not in 26.3+)
#   freetype  LWJGL >= 3.3.3
#   vulkan    26.2 and 26.3+: shaderc, spvc (SPIRV-Cross) and vma
#   sdl3      LWJGL 3.4.3 (26.3+)
# Flags override the derived defaults.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
[ "$#" -ge 2 ] || { echo "usage: $0 MC LWJGL [--from mc/DIR] [--regen] [--sdl3] [--no-glfw] [--no-tinyfd] [--no-freetype] [--vulkan]" >&2; exit 2; }
MC=$1; LW=$2; shift 2
FROM=; REGEN=
F_SDL=; F_NOGLFW=; F_NOTINYFD=; F_NOFT=; F_VK=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sdl3) F_SDL=1 ;;
    --no-glfw) F_NOGLFW=1 ;;
    --no-tinyfd) F_NOTINYFD=1 ;;
    --no-freetype) F_NOFT=1 ;;
    --vulkan) F_VK=1 ;;
    --regen) REGEN=1 ;;
    --from) FROM=$2; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

# --- derived feature set ---------------------------------------------------
GLFW=1; TINYFD=1; FT=; VK=; SDL=
case "$MC" in 1.13|1.13.*|1.14|1.14.*) TINYFD= ;; esac
case "$LW" in
  3.3.3|3.4.*) FT=1 ;;
esac
case "$LW" in 3.4.[2-9]|3.4.[1-9][0-9]|3.[5-9].*) GLFW=; TINYFD=; SDL=1; VK=1 ;; esac
[ "$MC" != 26.2 ] || VK=1
[ -z "$F_SDL" ] || { SDL=1; GLFW=; TINYFD=; }
[ -z "$F_NOGLFW" ] || GLFW=
[ -z "$F_NOTINYFD" ] || TINYFD=
[ -z "$F_NOFT" ] || FT=
[ -z "$F_VK" ] || VK=1

# --- pinned upstream refs --------------------------------------------------
case "$LW" in
  3.4.3|3.4.[4-9]|3.[5-9].*) FT_REF=VER-2-14-3 ;;
  3.4.*)                     FT_REF=VER-2-14-1 ;;
  *)                         FT_REF=VER-2-13-2 ;;
esac
# LWJGL-CI only publishes an LWJGL-3.4.3 tag; the shaderc/spvc C API is stable across 3.4.x.
VK_REF=LWJGL-3.4.3
SDL_REF=release-3.4.18

D=$ROOT/mc/$MC
if [ -n "$REGEN" ]; then
  [ -d "$D" ] || { echo "$D does not exist" >&2; exit 1; }
else
  [ ! -e "$D" ] || { echo "$D already exists" >&2; exit 1; }
fi
mkdir -p "$D/patches/libffi" "$D/patches/lwjgl3" "$D/patches/jemalloc" "$D/patches/openal"
[ -z "$GLFW" ] || mkdir -p "$D/patches/glfw"
[ -z "$SDL" ] || mkdir -p "$D/patches/sdl3"
[ -z "$FT" ] || mkdir -p "$D/patches/freetype"
[ -z "$VK" ] || mkdir -p "$D/patches/shaderc" "$D/patches/spvc"

NAT="liblwjgl.so libjemalloc.so libopenal.so liblwjgl_opengl.so liblwjgl_stb.so"
COMP="libffi"
[ -z "$GLFW" ] || { NAT="$NAT libglfw.so"; COMP="$COMP glfw"; }
COMP="$COMP lwjgl3 jemalloc openal"
[ -z "$TINYFD" ] || NAT="$NAT liblwjgl_tinyfd.so"
[ -z "$FT" ] || { NAT="$NAT libfreetype.so"; COMP="$COMP freetype"; }
[ -z "$VK" ] || { NAT="$NAT liblwjgl_vma.so libshaderc.so libspirv-cross.so"; COMP="$COMP shaderc spvc"; }
[ -z "$SDL" ] || { NAT="$NAT libSDL3.so"; COMP="$COMP sdl3"; }

{
  echo "# Minecraft $MC"
  echo "MC_VERSION=$MC"
  echo "LWJGL_VERSION=$LW"
  echo "LWJGL_URL=\${LWJGL_URL:-https://github.com/LWJGL/lwjgl3.git}"
  echo "LWJGL_REF=\${LWJGL_REF:-$LW}"
  echo "# GLFW, jemalloc and OpenAL Soft keep a stable C ABI, so one pinned ref serves"
  echo "# every version. Override here if a release ever needs an exact match."
  [ -z "$GLFW" ] || {
    echo "GLFW_URL=\${GLFW_URL:-https://github.com/glfw/glfw.git}"
    echo "GLFW_REF=\${GLFW_REF:-3.5.1}"
  }
  echo "JEMALLOC_URL=\${JEMALLOC_URL:-https://github.com/jemalloc/jemalloc.git}"
  echo "JEMALLOC_REF=\${JEMALLOC_REF:-5.3.0}"
  echo "OPENAL_URL=\${OPENAL_URL:-https://github.com/kcat/openal-soft.git}"
  echo "OPENAL_REF=\${OPENAL_REF:-1.23.1}"
  echo "# Static libffi for liblwjgl.so; the SunOS ant config requires LWJGL_SUNOS_LIBFFI_A."
  echo "LIBFFI_URL=\${LIBFFI_URL:-https://github.com/libffi/libffi.git}"
  echo "LIBFFI_REF=\${LIBFFI_REF:-v3.8.0}"
  [ -z "$FT" ] || {
    echo "# FreeType (the version LWJGL $LW ships)."
    echo "FREETYPE_URL=\${FREETYPE_URL:-https://github.com/freetype/freetype.git}"
    echo "FREETYPE_REF=\${FREETYPE_REF:-$FT_REF}"
  }
  [ -z "$VK" ] || {
    echo "# LWJGL's CI forks fold glslang/SPIRV-Tools into libshaderc and export the"
    echo "# SPIRV-Cross C API; the stock upstream repositories are not enough."
    echo "SHADERC_URL=\${SHADERC_URL:-https://github.com/LWJGL-CI/shaderc.git}"
    echo "SHADERC_REF=\${SHADERC_REF:-$VK_REF}"
    echo "SPVC_URL=\${SPVC_URL:-https://github.com/LWJGL-CI/SPIRV-Cross.git}"
    echo "SPVC_REF=\${SPVC_REF:-$VK_REF}"
  }
  [ -z "$SDL" ] || {
    echo "# SDL3 release; any 3.4.x works (stable ABI), the patch only touches CMakeLists.txt."
    echo "SDL3_URL=\${SDL3_URL:-https://github.com/libsdl-org/SDL.git}"
    echo "SDL3_REF=\${SDL3_REF:-$SDL_REF}"
  }
  echo "COMPONENTS=\"$COMP\""
  echo "NATIVES=\"$NAT\""
} > "$D/version.env"

if [ -n "$REGEN" ]; then
  for p in "$D"/patches/*; do
    [ -n "$(ls -A "$p" 2>/dev/null)" ] || : > "$p/.gitkeep"
  done
  echo "regenerated $D/version.env"; exit 0
fi

cat > "$D/build.sh" <<'EOS'
#!/usr/xpg4/bin/sh
# Build the SPARC Solaris natives for this Minecraft release.
# Config: version.env   Patches: patches/<component>/*.patch
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/driver.sh"
mc_main "$HERE" "$@"
EOS
chmod +x "$D/build.sh"

if [ -n "$FROM" ]; then
  (cd "$ROOT/$FROM/patches" 2>/dev/null || cd "$FROM/patches" && tar cf - .) | (cd "$D/patches" && tar xpf -)
fi
for p in "$D"/patches/*; do
  [ -n "$(ls -A "$p" 2>/dev/null)" ] || : > "$p/.gitkeep"
done
echo "created $D"
