#!/bin/sh
set -eu
export JAVA_HOME=/usr/jdk/instances/jdk21
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/launcher.py" "1.21"
