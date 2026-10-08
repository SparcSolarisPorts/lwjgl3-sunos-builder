#!/usr/xpg4/bin/sh
# Build the SPARC Solaris natives for this Minecraft release.
# Config: version.env   Patches: patches/<component>/*.patch
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/driver.sh"
mc_main "$HERE" "$@"
