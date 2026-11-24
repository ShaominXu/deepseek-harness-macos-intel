#!/bin/bash
# Pre-seed the Desktop primary-runtime download cache from the release lock.
# GitHub release assets and files.pythonhosted.org stall for plain Node fetch on some
# networks; curl handles them, and prepare-primary-runtime reuses these verified files.
set -euo pipefail
WS="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$WS/src}"
CACHE="${CACHE:-$WS/.caches/desktop-package/downloads}"
LOCK="$SRC/scripts/primary-runtime/lock.json"
mkdir -p "$CACHE"
python3 - "$LOCK" <<'PY' > "$CACHE/urls.txt"
import json, sys, urllib.parse
lock = json.load(open(sys.argv[1]))
t = lock['targets']['mac-x64']
node = f"https://nodejs.org/dist/v{lock['nodeVersion']}/node-v{lock['nodeVersion']}-{t['nodeArchive']}"
print(t['nodeSha256'], node)
py = f"cpython-{lock['pythonVersion']}+{lock['pythonRelease']}-{t['pythonTarget']}-install_only_stripped.tar.gz"
print(t['pythonSha256'], f"https://github.com/astral-sh/python-build-standalone/releases/download/{lock['pythonRelease']}/{urllib.parse.quote(py, safe='')}")
for w in t['wheels'] + lock['wheels']:
    print(w['sha256'], w['url'])
PY
fetch() {
  local sha="$1" url="$2" dest="$CACHE/$1"
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sha" ]; then echo "cached  ${sha:0:8}"; return; fi
  rm -f "$dest"
  echo "fetch   ${sha:0:8}  ${url##*/}"
  curl -fsSL --show-error --retry 5 --retry-delay 2 --connect-timeout 30 -m 1800 -o "$dest.part" "$url"
  if [ "$(shasum -a 256 "$dest.part" | cut -d' ' -f1)" != "$sha" ]; then echo "checksum mismatch: $url" >&2; rm -f "$dest.part"; return 1; fi
  mv "$dest.part" "$dest"
}
export CACHE
export -f fetch
awk 'NF==2' "$CACHE/urls.txt" | xargs -n 2 -P 6 bash -c 'fetch "$1" "$2"' _
rm -f "$CACHE/urls.txt"
echo "prefetch complete: $CACHE"
