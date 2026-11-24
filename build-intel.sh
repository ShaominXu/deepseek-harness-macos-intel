#!/bin/bash
# Build the official DeepSeek Harness Desktop (Electron) for Intel macOS.
#
# The release site only publishes the Apple Silicon DMG, but the official
# repository already carries the mac-x64 target (`package:desktop:mac:x64:unsigned`
# and .github/workflows/macos-intel-package.yml are the same path CI uses).
#
# Everything installs under this directory: the Node toolchain, the pnpm store,
# Electron/runtime archives and the checked-out source. Nothing touches a global
# Node, pnpm or cache. Expect roughly 4-6 GB of dependencies and 30-60 minutes
# on an Intel Mac with a warm network.
#
# Usage: ./build-intel.sh [--check]
#   --check   validate the packaging configuration and toolchain, then stop.
set -euo pipefail

WS="$(cd "$(dirname "$0")" && pwd)"
NODE_VERSION="${NODE_VERSION:-24.22.3}"
PNPM_VERSION="${PNPM_VERSION:-11.28.5}"
REPO="${REPO:-https://github.com/deepseek-ai/deepseek-harness.git}"
REF="${REF:-master}"
SRC="${SRC:-$WS/src}"
TOOLS="$WS/toolchain"
CACHES="$WS/.caches"

log() { printf '\n==> %s\n' "$*"; }

# 1. Pinned build toolchain (Node 24.22.3 satisfies the repository's engines range).
if [ ! -x "$TOOLS/node/bin/node" ]; then
  log "installing Node $NODE_VERSION into toolchain/"
  mkdir -p "$TOOLS"
  archive="$TOOLS/node-v$NODE_VERSION-darwin-x64.tar.gz"
  curl -fsSL --retry 5 --retry-delay 2 -o "$archive" \
    "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-x64.tar.gz"
  tar -xzf "$archive" -C "$TOOLS"
  mv "$TOOLS/node-v$NODE_VERSION-darwin-x64" "$TOOLS/node"
fi

mkdir -p "$CACHES"/{npm,pnpm-store,xdg,xdg-data,xdg-config,xdg-state,electron,electron-builder,desktop-package}
export PATH="$TOOLS/node/bin:$TOOLS/node_modules/.bin:$PATH"
export npm_config_cache="$CACHES/npm"
export XDG_CACHE_HOME="$CACHES/xdg"
export XDG_DATA_HOME="$CACHES/xdg-data"
export XDG_CONFIG_HOME="$CACHES/xdg-config"
export XDG_STATE_HOME="$CACHES/xdg-state"
export ELECTRON_CACHE="$CACHES/electron"
export ELECTRON_BUILDER_CACHE="$CACHES/electron-builder"
export DSH_DESKTOP_PACKAGE_CACHE_DIR="$CACHES/desktop-package"
# GitHub release assets stall for Node's fetch on some networks; the npmmirror
# copy of Electron uses the same checksums. Override for a non-CN network.
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS="${DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS:-600000}"
export DSH_TELEMETRY_DISABLED=1

if [ ! -x "$TOOLS/node_modules/.bin/pnpm" ] || [ "$("$TOOLS/node_modules/.bin/pnpm" --version 2>/dev/null || true)" != "$PNPM_VERSION" ]; then
  log "installing pnpm $PNPM_VERSION"
  npm --prefix "$TOOLS" install "pnpm@$PNPM_VERSION" --no-fund --no-audit --loglevel=error
fi

# 2. Official source at the requested ref.
if [ ! -d "$SRC/.git" ]; then
  log "cloning $REPO ($REF)"
  git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
fi

# 3. Locked dependencies.
if [ ! -d "$SRC/node_modules" ]; then
  log "installing workspace dependencies"
  (cd "$SRC" && pnpm install --frozen-lockfile)
fi

# 4. Pre-seed the runtime archives that Node's fetch cannot reach reliably here.
log "pre-seeding primary-runtime archives"
SRC="$SRC" "$WS/prefetch-runtime.sh"

# 5. Build and package. --check stops after configuration/toolchain validation.
DMG="$SRC/apps/desktop/.desktop-build/targets/mac-x64/unsigned-artifacts/deepseek-harness-$(node -p "require('$SRC/apps/desktop/package.json').version")-mac-x64-unsigned.dmg"
if [ "${1:-}" = "--check" ]; then
  log "validating packaging configuration"
  (cd "$SRC" && pnpm run package:desktop:mac:x64:unsigned --check)
  log "configuration valid"
  exit 0
fi

if [ -f "$DMG" ] && [ "${FORCE:-0}" != "1" ]; then
  log "DMG already present (set FORCE=1 to rebuild): $DMG"
else
  log "packaging DeepSeek Harness Desktop for mac-x64 (unsigned)"
  # The runtime smoke test opens /dev/ptmx through node-pty, so run this from a
  # normal Terminal: a macOS seatbelt/sandbox profile that denies /dev/ptmx
  # makes the build fail at "runtime:smoke".
  (cd "$SRC" && pnpm run package:desktop:mac:x64:unsigned)
fi

mkdir -p "$WS/dist"
cp "$DMG" "$WS/dist/"
(cd "$WS/dist" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS)

log "done"
printf 'DMG: %s\n' "$WS/dist/$(basename "$DMG")"
printf 'Install: open the DMG and drag "DeepSeek Harness.app" into /Applications.\n'
