#!/bin/bash
# pull-on-pod.sh — Fetch the latest LM Link with YaRN release from
# NextLVLHasH/AgentsRemoteBuild and stage it at $PERSIST/llama.cpp-prebuilt
# where installstart.sh expects it. Idempotent: skips download if the
# current release's tarball is already extracted on disk.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NextLVLHasH/AgentsRemoteBuild/main/pull-on-pod.sh | bash
#
# Or, with a non-default persistent mount:
#   PERSIST=/runpod-volume bash <(curl -fsSL .../pull-on-pod.sh)

set -euo pipefail

PERSIST="${PERSIST:-/workspace}"
REPO="${REPO:-NextLVLHasH/AgentsRemoteBuild}"
DEST="$PERSIST/llama.cpp-prebuilt"

if [ ! -d "$PERSIST" ]; then
  echo "ERROR: \$PERSIST=$PERSIST does not exist. Set PERSIST to your"
  echo "       template's persistent mount (/workspace on most RunPod"
  echo "       templates, sometimes /runpod-volume or /persistent)."
  exit 1
fi

mkdir -p "$DEST"
cd "$DEST"

# Find the latest Linux CUDA asset on the latest release. We grep for both
# the long-form filename pattern and a fallback to whatever Linux + cuda
# artifact is published.
echo "==> querying $REPO for latest release"
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)
if [ -z "$RELEASE_JSON" ] || echo "$RELEASE_JSON" | grep -q '"message": *"Not Found"'; then
  echo "ERROR: no releases published yet at https://github.com/$REPO/releases"
  echo "       Build one with build-release.sh and publish via 'gh release create'."
  exit 1
fi

# Extract the tarball URL. Prefer "lm-link-yarn-*-linux-x64-cuda12.tar.gz"
# matching exactly, fall back to any tarball with "linux" + "cuda" in the
# name (handles future renames).
ASSET_URL=$(echo "$RELEASE_JSON" \
  | grep -oE '"browser_download_url"\s*:\s*"[^"]+"' \
  | sed -E 's/.*"(https[^"]+)".*/\1/' \
  | grep -E 'lm-link-yarn-.*-linux-x64-cuda12\.tar\.gz$' \
  | head -1)
if [ -z "$ASSET_URL" ]; then
  ASSET_URL=$(echo "$RELEASE_JSON" \
    | grep -oE '"browser_download_url"\s*:\s*"[^"]+"' \
    | sed -E 's/.*"(https[^"]+)".*/\1/' \
    | grep -iE 'linux.*cuda.*\.tar\.gz$' \
    | head -1)
fi
if [ -z "$ASSET_URL" ]; then
  echo "ERROR: no Linux+CUDA tarball found in latest release of $REPO"
  exit 1
fi

ASSET_NAME=$(basename "$ASSET_URL")
TARBALL="$DEST/$ASSET_NAME"
EXTRACTED_DIR="${ASSET_NAME%.tar.gz}"

# Skip if already extracted (compare release-asset name to whatever's on disk)
if [ -x "$DEST/$EXTRACTED_DIR/bin/llama-server" ]; then
  echo "==> already at latest: $DEST/$EXTRACTED_DIR/bin/llama-server"
  exit 0
fi

echo "==> downloading $ASSET_NAME"
curl -fsSL -o "$TARBALL" "$ASSET_URL"
echo "    $(du -h "$TARBALL" | awk '{print $1}')"

# Verify sha256 if a .sha256 file is published next to the tarball
SHA_URL="${ASSET_URL}.sha256"
if curl -fsSL -o "$TARBALL.sha256" "$SHA_URL" 2>/dev/null; then
  EXPECTED=$(awk '{print $1}' < "$TARBALL.sha256")
  ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "ERROR: sha256 mismatch — expected $EXPECTED, got $ACTUAL"
    exit 1
  fi
  echo "    sha256 verified"
fi

echo "==> extracting"
tar -C "$DEST" -xzf "$TARBALL"

# Symlink the binary to a stable path so installstart.sh finds it without
# knowing the version-stamped directory name.
ln -sfn "$DEST/$EXTRACTED_DIR/bin/llama-server" "$DEST/llama-server"

# Same for the lib dir so LD_LIBRARY_PATH stays stable across releases.
ln -sfn "$DEST/$EXTRACTED_DIR/lib" "$DEST/lib"

echo
echo "==> done"
echo "    binary:  $DEST/llama-server -> $DEST/$EXTRACTED_DIR/bin/llama-server"
echo "    libs:    $DEST/lib          -> $DEST/$EXTRACTED_DIR/lib"
echo
echo "    Add to PATH (already done if you also run installstart.sh):"
echo "        export PATH=\"$DEST:\$PATH\""
echo "        export LD_LIBRARY_PATH=\"$DEST/lib:\${LD_LIBRARY_PATH:-}\""
