#!/bin/sh
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/launcher.py" \
  --fabric \
  --base-version 26.3 \
  --loader-profile "${MC_FABRIC_LOADER_PROFILE:-fabric-loader-0.19.5-26.3}"
