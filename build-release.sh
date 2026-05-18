#!/bin/bash
# build-release.sh — Build a portable YaRN-capable llama-server release for
# Linux x86_64 + CUDA 12, packaged so anyone can drop it in for LM Studio's
# bundled llama.cpp runtime ("LM Link with YaRN") OR run it standalone.
#
# Output: ./release/lm-link-yarn-<llama-cpp-ref>-linux-x64-cuda12.tar.gz
#
# Run this inside a Linux/WSL environment with CUDA 12 toolkit installed.
# Not portable to macOS / Windows native — those need their own build runs.
#
# Usage:
#   chmod +x build-release.sh
#   ./build-release.sh                # build at llama.cpp/master
#   LLAMA_REF=b4500 ./build-release.sh   # pin a specific release tag
#
# After the script finishes, upload release/*.tar.gz to GitHub via:
#   gh release create v0.1.0 release/*.tar.gz --notes-file release/README.md

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
WORKDIR="${WORKDIR:-$(pwd)/.build}"          # temp build dir; keep small
LLAMA_REPO="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}"
LLAMA_REF="${LLAMA_REF:-master}"             # branch, tag, or commit sha
RELEASE_DIR="${RELEASE_DIR:-$(pwd)/release}"
JOBS="$(nproc 2>/dev/null || echo 4)"

# Output naming. The platform tag goes in the filename so users on the wrong
# distro / CUDA version know at a glance whether the artifact matches.
PLATFORM="linux-x64-cuda12"
PACKAGE_NAME_BASE="lm-link-yarn"

step() { echo; echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. Sanity-check the build environment
# ---------------------------------------------------------------------------
step "1/6  Environment check"
case "$(uname -s)" in
  Linux) ;;
  *) echo "ERROR: this script only builds on Linux (you're on $(uname -s))."; exit 1 ;;
esac

MISSING=()
for tool in git cmake g++ make tar curl; do
  have "$tool" || MISSING+=("$tool")
done
if ! have nvcc; then
  echo "ERROR: nvcc not on PATH. Install the CUDA 12 toolkit:"
  echo "       sudo apt-get install -y nvidia-cuda-toolkit  # quick path (older CUDA)"
  echo "       — or follow https://developer.nvidia.com/cuda-downloads for current CUDA 12.x"
  exit 1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Installing missing tools: ${MISSING[*]}"
  sudo apt-get update && sudo apt-get install -y build-essential cmake git curl tar
fi

echo "    nvcc:  $(nvcc --version | head -1)"
echo "    cmake: $(cmake --version | head -1)"
echo "    gcc:   $(gcc --version | head -1)"

# ---------------------------------------------------------------------------
# 2. Clone llama.cpp
# ---------------------------------------------------------------------------
step "2/6  Clone llama.cpp ($LLAMA_REF)"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ -d llama.cpp/.git ]; then
  (cd llama.cpp && git fetch --depth 1 origin "$LLAMA_REF" && git checkout "$LLAMA_REF")
else
  if [ "$LLAMA_REF" = "master" ] || [ "$LLAMA_REF" = "main" ]; then
    git clone --depth 1 "$LLAMA_REPO" llama.cpp
  else
    git clone "$LLAMA_REPO" llama.cpp
    (cd llama.cpp && git checkout "$LLAMA_REF")
  fi
fi
cd llama.cpp
LLAMA_SHA=$(git rev-parse --short HEAD)
echo "    head: $LLAMA_SHA"

# ---------------------------------------------------------------------------
# 3. Configure and build. CUDA + shared libs; skip tests, examples, web UI.
# ---------------------------------------------------------------------------
step "3/6  Build (-j $JOBS)"
rm -rf build
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_COMMON=ON \
  >/dev/null

# Build the server target plus the libs it links against. Probe for any ggml
# sub-target names that exist in this commit so we don't fail on a renamed
# target.
BUILD_TARGETS=(--target llama-server --target llama)
for tgt in ggml ggml-base ggml-cuda ggml-cpu; do
  if grep -rq "add_library($tgt" . 2>/dev/null; then
    BUILD_TARGETS+=(--target "$tgt")
  fi
done
cmake --build build --config Release "${BUILD_TARGETS[@]}" -j "$JOBS"

# Strip debug symbols to shrink the artifact (50%+ reduction typical).
find build/bin -type f \( -name "llama-server" -o -name "*.so*" \) -exec strip --strip-unneeded {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Stage the release directory
# ---------------------------------------------------------------------------
STAGE="$WORKDIR/stage"
PACKAGE_NAME="${PACKAGE_NAME_BASE}-${LLAMA_SHA}-${PLATFORM}"
PACKAGE_DIR="$STAGE/$PACKAGE_NAME"

step "4/6  Stage release at $PACKAGE_DIR"
rm -rf "$STAGE"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/lib"

cp -v build/bin/llama-server "$PACKAGE_DIR/bin/" 2>&1 | sed 's/^/    /'
# All .so files end up in build/bin or build/src; copy whichever exists.
find build -maxdepth 3 \( -name "libllama.so*" -o -name "libggml*.so*" -o -name "libmtmd.so*" \) -type f -exec cp -v {} "$PACKAGE_DIR/lib/" \; 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 5. Add launcher + drop-in script + README
# ---------------------------------------------------------------------------
step "5/6  Add launcher, drop-in script, README"

# Launcher wrapper — sets LD_LIBRARY_PATH so the binary finds the bundled .so
# files regardless of where the user extracted the tarball.
cat > "$PACKAGE_DIR/run-llama-server" <<'LAUNCHER'
#!/bin/bash
# Wrapper: makes llama-server use the bundled .so files in this directory.
HERE="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$HERE/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/bin/llama-server" "$@"
LAUNCHER
chmod +x "$PACKAGE_DIR/run-llama-server"

# Drop-in helper for LM Studio users — overlays the bundled libs into
# LM Studio's CUDA runtime backend. Backs up originals as .lmstudio-bak.
cat > "$PACKAGE_DIR/install-into-lmstudio.sh" <<'OVERLAY'
#!/bin/bash
# install-into-lmstudio.sh — overlay these YaRN-capable libs into LM Studio's
# bundled llama.cpp runtime so `lms load` uses the new build.
# Backs up originals as <name>.lmstudio-bak; restore command at the end.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Find LM Studio's CUDA backend on either old or new install layout
for root in "$HOME/.lmstudio" "$HOME/.cache/lm-studio"; do
  if [ -d "$root/extensions/backends" ]; then
    BACKEND=$(find "$root/extensions/backends" -maxdepth 1 -type d -name "llama.cpp-linux-*nvidia-cuda*" 2>/dev/null | head -1)
    [ -n "$BACKEND" ] && break
  fi
done

if [ -z "${BACKEND:-}" ]; then
  echo "ERROR: no LM Studio CUDA backend found. Run 'lms bootstrap' first."
  exit 1
fi

echo "Target: $BACKEND"
overlay_one() {
  local src="$HERE/lib/$1" dst="$BACKEND/$2"
  [ -f "$src" ] || { echo "  skip $2 (no $1 in package)"; return; }
  if [ -f "$dst" ] && [ ! -f "${dst}.lmstudio-bak" ]; then
    cp -p "$dst" "${dst}.lmstudio-bak"
  fi
  cp -f "$src" "$dst"
  echo "  overlay: $2 (backup at ${dst}.lmstudio-bak)"
}

overlay_one libllama.so libllama.so
overlay_one libggml.so libggml_llamacpp.so
[ -f "$HERE/lib/libggml.so" ] || overlay_one libggml-base.so libggml_llamacpp.so

echo
echo "Done. To restore LM Studio's original libs:"
echo "  for f in \"$BACKEND\"/*.lmstudio-bak; do mv -f \"\$f\" \"\${f%.lmstudio-bak}\"; done"
OVERLAY
chmod +x "$PACKAGE_DIR/install-into-lmstudio.sh"

# README
cat > "$PACKAGE_DIR/README.md" <<README
# LM Link with YaRN

Portable build of \`llama-server\` from [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) (\`$LLAMA_SHA\`) for **Linux x86_64 + CUDA 12**, packaged with all required shared libraries and a one-line LM Studio drop-in installer.

## What's inside

\`\`\`
$PACKAGE_NAME/
├── bin/llama-server              # the CUDA-enabled HTTP server binary
├── lib/libllama.so               # llama.cpp runtime
├── lib/libggml*.so               # ggml backends (cpu, cuda, base)
├── run-llama-server              # wrapper that sets LD_LIBRARY_PATH
├── install-into-lmstudio.sh      # overlay into LM Studio's bundled runtime
└── README.md
\`\`\`

## Standalone use (recommended)

Run as your inference endpoint without touching LM Studio:

\`\`\`
./run-llama-server \\
  --model /path/to/model.gguf \\
  --host 0.0.0.0 --port 1234 \\
  --n-gpu-layers 999 \\
  --ctx-size 1010000 \\
  --rope-scaling yarn --rope-scale 4 --rope-freq-base 10000000 --yarn-orig-ctx 262144 \\
  --cache-type-k q8_0 --cache-type-v q8_0
\`\`\`

The \`--rope-scaling yarn …\` flags extend Qwen3.6's 262k native context to ~1M. KV-cache quantization (\`--cache-type-k/v q8_0\`) is mandatory at 1M context on a 96 GB GPU; FP16 KV would need ~96 GB by itself.

Endpoint becomes OpenAI-compatible at \`http://0.0.0.0:1234/v1\`.

## LM Studio drop-in

LM Studio 2.13+ ships only a merged \`libggml_llamacpp.so\` library — no standalone llama-server binary, and \`lms load\` doesn't expose YaRN flags. To get YaRN behavior through the LM Studio path:

\`\`\`
./install-into-lmstudio.sh
\`\`\`

That overlays \`bin/lib/libllama.so\` and \`bin/lib/libggml.so\` into LM Studio's CUDA backend directory, backing up originals as \`<name>.lmstudio-bak\`.

If \`lms load\` breaks afterward (LM Studio's loader is built against the merged-library ABI, ours uses the split form), restore with:

\`\`\`
BACKEND=\$(find ~/.cache/lm-studio/extensions/backends ~/.lmstudio/extensions/backends -maxdepth 1 -type d -name "llama.cpp-linux-*nvidia-cuda*" | head -1)
for f in "\$BACKEND"/*.lmstudio-bak; do mv -f "\$f" "\${f%.lmstudio-bak}"; done
\`\`\`

## Requirements

- Linux x86_64
- CUDA 12.x runtime (\`/usr/lib/x86_64-linux-gnu/libcudart.so.12\` or matching). Earlier CUDA versions won't load the binary.
- glibc 2.31+ (Ubuntu 20.04 LTS or newer)

## Source

Built from \`$LLAMA_REPO\` at commit \`$LLAMA_SHA\`. Reproducible build:

\`\`\`
git clone $LLAMA_REPO && cd llama.cpp && git checkout $LLAMA_SHA
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DBUILD_SHARED_LIBS=ON \\
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build --config Release --target llama-server -j \$(nproc)
\`\`\`
README

# ---------------------------------------------------------------------------
# 6. Tar it up
# ---------------------------------------------------------------------------
step "6/6  Pack release"
mkdir -p "$RELEASE_DIR"
TARBALL="$RELEASE_DIR/${PACKAGE_NAME}.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "$PACKAGE_NAME"
echo "    $TARBALL"
ls -lh "$TARBALL" | awk '{print "    size: "$5}'

# Compute a checksum so GitHub release notes can include it
sha256sum "$TARBALL" > "${TARBALL}.sha256"
echo "    sha256: $(cat "${TARBALL}.sha256" | awk '{print $1}')"

# Also drop a copy of the package README at the release root so `gh release
# create … --notes-file release/README.md` works without --notes editing.
cp "$PACKAGE_DIR/README.md" "$RELEASE_DIR/README.md"

echo
echo "==> Done."
echo "    Upload with:  gh release create v0.1.0 \"$TARBALL\" \"${TARBALL}.sha256\" --notes-file \"$RELEASE_DIR/README.md\""
