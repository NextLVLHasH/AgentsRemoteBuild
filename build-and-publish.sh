#!/bin/bash
# build-and-publish.sh — Run build-release.sh, then publish the resulting
# tarball as a GitHub release on this repo. One command, end to end.
#
# Run this in WSL (or any Linux box) with CUDA 12 + gh CLI installed and
# authenticated (`gh auth login`).
#
# Usage:
#   chmod +x build-and-publish.sh
#   ./build-and-publish.sh                    # auto version tag from llama.cpp sha
#   VERSION=v0.2.0 ./build-and-publish.sh     # explicit tag
#   LLAMA_REF=b4500 ./build-and-publish.sh    # pin a specific llama.cpp commit/tag
#
# What it does:
#   1. Runs ./build-release.sh — clones llama.cpp, builds llama-server with
#      CUDA + shared libs + YaRN support, packages as
#      release/lm-link-yarn-<sha>-linux-x64-cuda12.tar.gz
#   2. Computes a release tag (default: yarn-<llama.cpp short sha> with a
#      monotonic suffix if it already exists)
#   3. Runs `gh release create` to publish the tarball + sha256 + README.

set -euo pipefail

REPO="${REPO:-NextLVLHasH/AgentsRemoteBuild}"

step() { echo; echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. Pre-flight — gh CLI installed and authenticated
# ---------------------------------------------------------------------------
step "1/4  pre-flight"
if ! have gh; then
  echo "ERROR: gh CLI not installed."
  echo "       Install it from https://cli.github.com/  (apt: sudo apt-get install gh)"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login"
  exit 1
fi
echo "    gh:   $(gh --version | head -1)"
echo "    user: $(gh api user --jq .login)"

# Make sure we can hit the target repo (catches typos / missing-repo / wrong-org early).
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  echo "ERROR: $REPO not accessible. Either the repo doesn't exist yet, or you"
  echo "       don't have permission. Create it with:"
  echo "           gh repo create $REPO --public --source=. --push"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Build the release tarball via build-release.sh
# ---------------------------------------------------------------------------
step "2/4  build"
HERE="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$HERE/build-release.sh"
"$HERE/build-release.sh"

# Locate the tarball + sha256 we just produced
TARBALL=$(ls -t "$HERE/release"/lm-link-yarn-*linux-x64-cuda12.tar.gz 2>/dev/null | head -1)
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
  echo "ERROR: build-release.sh ran but no tarball at $HERE/release/"
  exit 1
fi
SHA256="${TARBALL}.sha256"
NOTES="$HERE/release/README.md"
echo "    artifact: $TARBALL"
echo "    sha256:   $SHA256"

# ---------------------------------------------------------------------------
# 3. Pick a version tag. If VERSION isn't set, derive one from the llama.cpp
#    short sha embedded in the tarball name (e.g. yarn-b4500). If the tag
#    already exists on the repo, suffix -2, -3, … until we find a free one.
# ---------------------------------------------------------------------------
step "3/4  pick version tag"
if [ -n "${VERSION:-}" ]; then
  TAG="$VERSION"
else
  BASE_SHA=$(basename "$TARBALL" | sed -E 's/^lm-link-yarn-([^-]+)-.*/\1/')
  TAG="yarn-$BASE_SHA"
  i=1
  while gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; do
    i=$((i+1))
    TAG="yarn-${BASE_SHA}-${i}"
  done
fi
echo "    tag: $TAG"

# ---------------------------------------------------------------------------
# 4. Publish
# ---------------------------------------------------------------------------
step "4/4  gh release create"
TITLE="LM Link with YaRN — $TAG"
gh release create "$TAG" \
  "$TARBALL" "$SHA256" \
  --repo "$REPO" \
  --title "$TITLE" \
  --notes-file "$NOTES"

echo
echo "==> Released: https://github.com/$REPO/releases/tag/$TAG"
echo
echo "    Asset URL (used by installstart.sh and pull-on-pod.sh):"
echo "        https://github.com/$REPO/releases/latest/download/$(basename "$TARBALL")"
echo
echo "    Pod-side one-liner to pull this build:"
echo "        curl -fsSL https://raw.githubusercontent.com/$REPO/main/pull-on-pod.sh | bash"
