#!/bin/bash
# install-agents.sh — End-user installer for the HasH AI desktop app.
# Fetches the latest release artifact from NextLVLHasH/AgentsRemoteBuild and
# either launches the AppImage (Linux) or downloads the .exe installer
# (Windows via Git Bash / WSL).
#
# Use it as a curl one-liner:
#   curl -fsSL https://raw.githubusercontent.com/NextLVLHasH/AgentsRemoteBuild/main/install-agents.sh | bash
#
# Source for HasH AI is NOT public — only the compiled installer is. This
# script never clones / fetches source, only the release artifact.

set -euo pipefail

REPO="${REPO:-NextLVLHasH/AgentsRemoteBuild}"
DEST="${DEST:-$HOME/Applications/HasH-AI}"

have() { command -v "$1" >/dev/null 2>&1; }
err()  { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Detect platform → pick which artifact to pull
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Linux)
    KIND="AppImage"
    EXT=".AppImage"
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    KIND="exe"
    EXT=".exe"
    ;;
  Darwin)
    KIND="dmg"
    EXT=".dmg"
    ;;
  *)
    err "Unsupported platform: $(uname -s)"
    ;;
esac

echo "==> Platform: $KIND"

have curl || err "curl is required. Install with: sudo apt-get install -y curl"

# ---------------------------------------------------------------------------
# 2. Find the right asset on the latest release. We grep the release JSON for
#    a browser_download_url ending in the platform's extension and excluding
#    sidecar files (.sha256, .blockmap).
# ---------------------------------------------------------------------------
echo "==> Querying latest release on $REPO"
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)
if [ -z "$RELEASE_JSON" ] || echo "$RELEASE_JSON" | grep -q '"message": *"Not Found"'; then
  err "No releases yet at https://github.com/$REPO/releases — ask the maintainer to publish one."
fi

ASSET_URL=$(echo "$RELEASE_JSON" \
  | grep -oE '"browser_download_url"\s*:\s*"[^"]+"' \
  | sed -E 's/.*"(https[^"]+)".*/\1/' \
  | grep -E "${EXT}\$" \
  | grep -ivE '\.(sha256|blockmap|yml)$' \
  | head -1)

if [ -z "$ASSET_URL" ]; then
  err "No $KIND artifact in the latest release. Available assets: $(echo "$RELEASE_JSON" | grep -oE '"name"\s*:\s*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | paste -sd, -)"
fi

ASSET_NAME=$(basename "$ASSET_URL")
echo "    asset: $ASSET_NAME"

# ---------------------------------------------------------------------------
# 3. Download
# ---------------------------------------------------------------------------
mkdir -p "$DEST"
TARGET="$DEST/$ASSET_NAME"
if [ -f "$TARGET" ]; then
  echo "==> Already downloaded: $TARGET"
else
  echo "==> Downloading to $TARGET"
  curl -fL --progress-bar -o "$TARGET" "$ASSET_URL"
fi

# Verify size is plausible (>10 MB; sanity check that nothing went wrong)
SIZE=$(stat -c %s "$TARGET" 2>/dev/null || stat -f %z "$TARGET")
if [ "$SIZE" -lt 10000000 ]; then
  err "Downloaded file is suspiciously small ($SIZE bytes). Try again or check GitHub release page."
fi

# ---------------------------------------------------------------------------
# 4. Post-install per platform
# ---------------------------------------------------------------------------
case "$KIND" in
  AppImage)
    chmod +x "$TARGET"
    echo
    echo "==> Installed."
    echo "    Run with: $TARGET"
    echo
    echo "    Optional — add a desktop shortcut:"
    echo "        $TARGET --appimage-extract-and-run     # one-off launch"
    echo "        Or install appimaged for auto-registration with your DE."
    ;;
  exe)
    echo
    echo "==> Downloaded."
    echo "    Launch the installer to install HasH AI:"
    echo "        cmd.exe /c start \"\" \"$TARGET\""
    echo "    Or double-click $TARGET from File Explorer."
    ;;
  dmg)
    echo
    echo "==> Downloaded."
    echo "    Open the disk image:  open \"$TARGET\""
    ;;
esac

echo
echo "    Release: https://github.com/$REPO/releases/latest"
