#!/bin/bash
# build-agents.sh — Build the HasH AI / Agents desktop app (Electron) into
# distributable artifacts:
#   - Windows EXE installer (NSIS) + portable zip — cross-built via Wine
#   - Linux AppImage + zip
# Both go into $RELEASE_DIR so build-and-publish.sh can attach them to the
# same gh release as the llama-server tarball.
#
# Pre-reqs on the build machine:
#   - Linux x86_64 (WSL Ubuntu works)
#   - Node.js 20+ and npm on PATH
#   - For Windows cross-build: wine, wine32, wine64, mono-complete (auto-installed
#     when running as root with apt available — otherwise install manually)
#   - ~3 GB free disk for the build tree + electron downloads
#
# Usage:
#   ./build-agents.sh                       # builds both win + linux
#   BUILD_TARGETS=win    ./build-agents.sh  # Windows EXE only
#   BUILD_TARGETS=linux  ./build-agents.sh  # Linux AppImage only
#   AGENTS_REF=v0.2.0    ./build-agents.sh  # pin a tag/branch
#   AGENTS_SRC=/path/to/Agents ./build-agents.sh  # use existing checkout

set -euo pipefail

AGENTS_REPO="${AGENTS_REPO:-https://github.com/NextLVLHasH/Agents.git}"
AGENTS_REF="${AGENTS_REF:-main}"
AGENTS_SRC="${AGENTS_SRC:-}"
RELEASE_DIR="${RELEASE_DIR:-$(pwd)/release}"
WORKDIR="${WORKDIR:-$(pwd)/.build}"
BUILD_TARGETS="${BUILD_TARGETS:-win,linux}"

step() { echo; echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. Pre-flight
# ---------------------------------------------------------------------------
step "1/4  pre-flight"
case "$(uname -s)" in
  Linux) ;;
  *) echo "ERROR: build runs on Linux only (you're on $(uname -s))."; exit 1 ;;
esac

# Node check. Electron-builder wants Node 16+; we want 20+ for the backend.
if ! have node; then
  echo "ERROR: node not on PATH. Install Node.js 20+:"
  echo "       curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
  echo "       sudo apt-get install -y nodejs"
  exit 1
fi
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "WARNING: node $NODE_MAJOR detected; npm install may complain. 20+ recommended."
fi
echo "    node: $(node --version)"
echo "    npm:  $(npm --version)"

# Wine + mono needed for Windows cross-build only.
if [[ ",$BUILD_TARGETS," == *",win,"* ]]; then
  if ! have wine; then
    if [ "$(id -u)" -eq 0 ] && have apt-get; then
      echo "    installing wine + mono for Windows cross-build (~500 MB)"
      dpkg --add-architecture i386
      apt-get update -qq
      apt-get install -y wine wine32 wine64 mono-complete
    elif have sudo; then
      echo "    installing wine + mono for Windows cross-build (~500 MB) via sudo"
      sudo dpkg --add-architecture i386
      sudo apt-get update -qq
      sudo apt-get install -y wine wine32 wine64 mono-complete
    else
      echo "ERROR: wine not installed and we can't auto-install (not root, no sudo)."
      echo "       Install manually:  sudo apt-get install -y wine wine32 wine64 mono-complete"
      echo "       Or skip Windows build:  BUILD_TARGETS=linux ./build-agents.sh"
      exit 1
    fi
  fi
  echo "    wine: $(wine --version)"
fi

# ---------------------------------------------------------------------------
# 2. Get the Agents source (clone fresh or use provided checkout)
# ---------------------------------------------------------------------------
step "2/4  Source ($AGENTS_REF)"
if [ -n "$AGENTS_SRC" ]; then
  if [ ! -d "$AGENTS_SRC/Frontend" ]; then
    echo "ERROR: AGENTS_SRC=$AGENTS_SRC has no Frontend/ subdir — wrong path?"
    exit 1
  fi
  SRC="$AGENTS_SRC"
  echo "    using local source: $SRC"
else
  mkdir -p "$WORKDIR"
  SRC="$WORKDIR/Agents"
  if [ -d "$SRC/.git" ]; then
    echo "    updating existing clone at $SRC"
    (cd "$SRC" && git fetch --depth 1 origin "$AGENTS_REF" && git checkout "$AGENTS_REF" && git pull --ff-only 2>/dev/null || true)
  else
    git clone --depth 1 --branch "$AGENTS_REF" "$AGENTS_REPO" "$SRC" 2>/dev/null \
      || { git clone "$AGENTS_REPO" "$SRC" && (cd "$SRC" && git checkout "$AGENTS_REF"); }
  fi
fi

# ---------------------------------------------------------------------------
# 3. npm install (Frontend + backend) and build
# ---------------------------------------------------------------------------
step "3/4  Build (Frontend + backend)"
cd "$SRC/Frontend"

# Clean any stale artifacts from previous Windows-host builds so electron-builder
# doesn't reuse a release/ dir with the wrong target.
rm -rf release/ dist/

echo "    npm install (Frontend)"
npm install --no-audit --no-fund

if [ -d backend ]; then
  echo "    npm install (backend)"
  (cd backend && npm install --no-audit --no-fund)
fi

# Build the renderer bundle + backend TS first. `npm start` does this implicitly,
# but `npm run dist` doesn't always — electron-builder packs whatever's on disk.
echo "    npm run build"
npm run build

# Now ask electron-builder for the platforms we want. The --publish never flag
# stops electron-builder from trying to push to its own GitHub release flow;
# we handle uploads via gh release create / gh release upload in build-and-publish.sh.
BUILDER_FLAGS=(--publish never)
if [[ ",$BUILD_TARGETS," == *",win,"* ]]; then
  BUILDER_FLAGS+=(--win)
fi
if [[ ",$BUILD_TARGETS," == *",linux,"* ]]; then
  BUILDER_FLAGS+=(--linux)
fi
if [[ ",$BUILD_TARGETS," == *",mac,"* ]]; then
  BUILDER_FLAGS+=(--mac)  # only works on macOS; left here for future use
fi

echo "    electron-builder ${BUILDER_FLAGS[*]}"
npx electron-builder "${BUILDER_FLAGS[@]}"

# ---------------------------------------------------------------------------
# 4. Copy produced artifacts to $RELEASE_DIR
# ---------------------------------------------------------------------------
step "4/4  Stage artifacts in $RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# electron-builder drops everything into Frontend/release/. We pull out the
# user-facing installer / zip / AppImage files and skip the unpacked dirs +
# metadata (latest.yml, blockmap, etc.) since gh releases only need the
# distributables.
for ext in exe AppImage zip dmg; do
  for f in release/*."$ext"; do
    [ -f "$f" ] || continue
    cp -v "$f" "$RELEASE_DIR/" | sed 's/^/    /'
  done
done

# Also copy the latest.yml metadata files — useful if you ever wire up
# electron-updater's auto-update against this same GitHub release.
for f in release/latest*.yml; do
  [ -f "$f" ] && cp "$f" "$RELEASE_DIR/"
done

echo
echo "==> Done."
echo "    Staged in $RELEASE_DIR:"
ls -lh "$RELEASE_DIR"/*.exe "$RELEASE_DIR"/*.AppImage "$RELEASE_DIR"/*.zip 2>/dev/null \
  | awk '{print "      " $NF " (" $5 ")"}'
