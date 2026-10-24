#!/bin/sh
set -eu
export JAVA_HOME=/usr/jdk/instances/jdk1.8.0
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/launcher.py" "1.13"
