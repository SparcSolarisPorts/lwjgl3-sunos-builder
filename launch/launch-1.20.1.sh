#!/bin/sh
set -eu
export JAVA_HOME=/export/home/solaris/Downloads/jdk-17.0.20
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/launcher.py" "1.20.1"
