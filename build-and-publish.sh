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
# 2.a Build the llama-server runtime tarball via build-release.sh
# ---------------------------------------------------------------------------
step "2.a/4  llama-server build"
HERE="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$HERE/build-release.sh"
"$HERE/build-release.sh"

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
# 2.b Build the HasH AI Electron app (Windows EXE + Linux AppImage) via
#     build-agents.sh. Source stays private; only built artifacts get
#     published to AgentsRemoteBuild's public release.
#
#     Skipped automatically if SKIP_AGENTS=1 or the script can't find an
#     Agents source (lets you publish a llama-server-only release if you
#     don't want to rebuild the desktop app every time).
# ---------------------------------------------------------------------------
step "2.b/4  Agents Electron app build"
if [ "${SKIP_AGENTS:-0}" = "1" ]; then
  echo "    SKIP_AGENTS=1 — not building the desktop app this run"
else
  chmod +x "$HERE/build-agents.sh"
  # If the user has a local Agents checkout on Windows (mounted at /mnt/c
  # under WSL) we prefer it — keeps source private, no clone needed. Falls
  # back to AGENTS_REPO clone when no local source is set.
  if [ -z "${AGENTS_SRC:-}" ] && [ -d "/mnt/c/Users/Davet/source/repos/Agents/Frontend" ]; then
    export AGENTS_SRC="/mnt/c/Users/Davet/source/repos/Agents"
    echo "    using local Agents checkout (private): $AGENTS_SRC"
  fi
  if "$HERE/build-agents.sh"; then
    echo "    Agents build succeeded"
  else
    echo "    WARNING: Agents build failed — continuing with llama-server-only release"
    echo "             (set SKIP_AGENTS=1 to suppress this attempt next time)"
  fi
fi

# Collect every Agents artifact that landed in release/ (.exe / .AppImage / .zip
# for the desktop app, plus the optional latest*.yml electron-updater feeds).
AGENTS_FILES=()
while IFS= read -r f; do
  AGENTS_FILES+=("$f")
done < <(find "$HERE/release" -maxdepth 1 \( -name "*.exe" -o -name "*.AppImage" -o -name "*.dmg" -o -name "HasH*.zip" -o -name "latest*.yml" \) -type f 2>/dev/null)
if [ "${#AGENTS_FILES[@]}" -gt 0 ]; then
  echo "    Agents artifacts:"
  for f in "${AGENTS_FILES[@]}"; do
    echo "      $(basename "$f")  ($(du -h "$f" | awk '{print $1}'))"
  done
fi

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
TITLE="HasH AI + LM Link with YaRN — $TAG"

# Upload llama-server tarball, sha256, and every Agents artifact in one go.
RELEASE_ASSETS=("$TARBALL" "$SHA256")
RELEASE_ASSETS+=("${AGENTS_FILES[@]}")

gh release create "$TAG" \
  "${RELEASE_ASSETS[@]}" \
  --repo "$REPO" \
  --title "$TITLE" \
  --notes-file "$NOTES"

echo
echo "==> Released: https://github.com/$REPO/releases/tag/$TAG"
echo
echo "    Runtime asset (used by installstart.sh / pull-on-pod.sh on RunPod pods):"
echo "        https://github.com/$REPO/releases/latest/download/$(basename "$TARBALL")"
if [ "${#AGENTS_FILES[@]}" -gt 0 ]; then
  echo
  echo "    Desktop app artifacts (for end users on Windows / Linux):"
  for f in "${AGENTS_FILES[@]}"; do
    case "$f" in
      *.exe)      echo "        https://github.com/$REPO/releases/latest/download/$(basename "$f")  (Windows installer)" ;;
      *.AppImage) echo "        https://github.com/$REPO/releases/latest/download/$(basename "$f")  (Linux AppImage)" ;;
      *.zip)      echo "        https://github.com/$REPO/releases/latest/download/$(basename "$f")  (portable zip)" ;;
    esac
  done
fi
echo
echo "    End-user one-liner install (HasH AI desktop app):"
echo "        curl -fsSL https://raw.githubusercontent.com/$REPO/main/install-agents.sh | bash"
