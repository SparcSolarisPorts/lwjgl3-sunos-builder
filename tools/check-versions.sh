#!/usr/xpg4/bin/sh
# Compare versions.conf with what Mojang's own version JSONs ship, so the
# LWJGL pin for every release is verified instead of remembered.
#   tools/check-versions.sh            report mismatches (exit 1 if any)
#   tools/check-versions.sh --all      list every release >= 1.13 with its LWJGL
# MANIFEST_URL can point at a file:// copy for offline testing.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
MANIFEST_URL=${MANIFEST_URL:-https://piston-meta.mojang.com/mc/game/version_manifest_v2.json}
MODE=check; [ "${1-}" = "--all" ] && MODE=all
ROOT=$ROOT MANIFEST_URL=$MANIFEST_URL MODE=$MODE python3 - <<'PY'
import json, os, sys, urllib.request
def get(u):
    with urllib.request.urlopen(u, timeout=60) as r: return json.load(r)
man = get(os.environ["MANIFEST_URL"])
rel = {v["id"]: v["url"] for v in man["versions"] if v["type"] == "release"}
def lwjgl(url):
    j = get(url); found = set()
    for l in j.get("libraries", []):
        p = l["name"].split(":")
        if p[0] == "org.lwjgl" and p[1] == "lwjgl": found.add(p[2])
    return sorted(found)
def key(v): return tuple(int(x) for x in v.split(".") if x.isdigit())
if os.environ["MODE"] == "all":
    for v in sorted(rel, key=key):
        if key(v) >= (1, 13):
            print("%-10s %s" % (v, ",".join(lwjgl(rel[v])) or "-"))
    sys.exit(0)
bad = 0
for line in open(os.path.join(os.environ["ROOT"], "versions.conf")):
    if line.startswith("#") or not line.strip(): continue
    mc, want = line.split("|")[:2]
    if mc not in rel:
        print("%-8s not in Mojang manifest (not released yet?)" % mc); continue
    got = lwjgl(rel[mc])
    ok = got == [want] or want in got  # a release may ship two (per-platform) versions
    bad += (not ok)
    print("%-8s versions.conf=%-6s mojang=%-10s %s" % (mc, want, ",".join(got) or "-", "ok" if ok else "MISMATCH"))
sys.exit(1 if bad else 0)
PY
