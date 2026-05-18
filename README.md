# AgentsRemoteBuild

Public release portal for **HasH AI** (the desktop coder app) and **LM Link with YaRN** (the long-context inference runtime).

This repo holds:

- The compiled **HasH AI installer** for Windows + Linux (latest builds in [Releases](https://github.com/NextLVLHasH/AgentsRemoteBuild/releases))
- A YaRN-capable **`llama-server`** binary for Linux + CUDA 12 (LM Link with YaRN)
- One-line install scripts for end users and for RunPod pods
- The build pipeline (run by the maintainer) — source code stays in a private repo

---

## End-user install (HasH AI desktop app)

### Windows

One-liner from PowerShell or Git Bash:

```
curl -fsSL https://raw.githubusercontent.com/NextLVLHasH/AgentsRemoteBuild/main/install-agents.sh | bash
```

…then double-click the `.exe` it downloads to your `Applications/HasH-AI/` folder. Or just grab the installer directly from the [latest release](https://github.com/NextLVLHasH/AgentsRemoteBuild/releases/latest) and double-click.

### Linux

```
curl -fsSL https://raw.githubusercontent.com/NextLVLHasH/AgentsRemoteBuild/main/install-agents.sh | bash
```

The AppImage lands at `~/Applications/HasH-AI/HasH AI-*.AppImage` with the executable bit already set. Run it directly.

### macOS

Not currently shipping a macOS build. Use the Linux AppImage under a Linux VM, or [build from source on a Mac](https://github.com/NextLVLHasH/Agents) (source repo is private — request access).

---

## RunPod inference setup (LM Link with YaRN)

For running large models like the uncensored Qwen3.6-40B at 1M context on a RunPod pod with an RTX Pro 6000 or similar 80GB+ GPU.

```
curl -fsSL https://raw.githubusercontent.com/NextLVLHasH/AgentsRemoteBuild/main/pull-on-pod.sh | bash
```

That fetches the latest YaRN-capable `llama-server` and bundled libs to `/workspace/llama.cpp-prebuilt/`. Then point any prompt at it via the [installstart.sh](https://github.com/NextLVLHasH/Linux-Install-Scripts/blob/main/installstart.sh) on the same pod, which auto-discovers this prebuilt and skips its source build.

Or run it directly:

```
/workspace/llama.cpp-prebuilt/run-llama-server \
  --model /workspace/models/<your-model>.gguf \
  --host 0.0.0.0 --port 1234 \
  --n-gpu-layers 999 --ctx-size 1010000 \
  --rope-scaling yarn --rope-scale 4 --rope-freq-base 10000000 --yarn-orig-ctx 262144 \
  --cache-type-k q8_0 --cache-type-v q8_0
```

Endpoint becomes OpenAI-compatible at `http://0.0.0.0:1234/v1`.

---

## Building releases (maintainer only)

The actual source for HasH AI lives in a separate (private) `Agents` repo. This repo holds the **build + publish pipeline** — runs on the maintainer's Linux box (WSL Ubuntu works), produces both the runtime tarball and the desktop installer, and uploads them to GitHub releases here.

### One-shot build + publish

```
# In WSL Ubuntu or any Linux box with CUDA 12 + gh authed:
cd ~/AgentsRemoteBuild
chmod +x build-and-publish.sh build-release.sh build-agents.sh
./build-and-publish.sh
```

What that does:

1. **Pre-flight** — `nvcc`, `gh auth status`, repo accessibility
2. **`build-release.sh`** — clones `ggml-org/llama.cpp` (current `master` by default; pin via `LLAMA_REF=`), builds with `-DGGML_CUDA=ON -DBUILD_SHARED_LIBS=ON`, packages binary + libs + wrapper + LM Studio overlay script
3. **`build-agents.sh`** — clones / uses local Agents source, builds the Electron app with electron-builder cross-targeting both Windows (NSIS installer + zip via Wine) and Linux (AppImage + zip)
4. **`gh release create`** — uploads `lm-link-yarn-*.tar.gz` + `*.sha256` + `*.exe` + `*.AppImage` + `*.zip` + electron-updater `latest.yml` all to a single release tagged `yarn-<llama-sha>`

### Skip the desktop app build

If you're only refreshing the inference runtime:

```
SKIP_AGENTS=1 ./build-and-publish.sh
```

### Build the desktop app only

```
./build-agents.sh
# Then upload manually:
gh release upload <tag> release/*.exe release/*.AppImage --repo NextLVLHasH/AgentsRemoteBuild
```

### Force a rebuild against the current llama.cpp main

```
FORCE=1 LLAMA_REF=master ./build-and-publish.sh
```

### Pin a specific llama.cpp release

```
LLAMA_REF=b4500 ./build-and-publish.sh
```

---

## Repo layout

```
AgentsRemoteBuild/
├── README.md                # this file — end-user + maintainer docs
├── install-agents.sh        # end users: download the HasH AI installer
├── pull-on-pod.sh           # RunPod pods: fetch llama-server prebuilt
├── build-and-publish.sh     # maintainer: run both builds + publish
├── build-release.sh         # maintainer: produce llama-server tarball only
├── build-agents.sh          # maintainer: produce HasH AI .exe + AppImage
└── .gitignore
```

## Why a separate repo

- **Source privacy.** The `Agents` repo can stay private — this public repo only carries built artifacts and install scripts. Anyone can install HasH AI without seeing source.
- **Release cadence.** Bumping the HasH AI desktop app shouldn't force a new `llama-server` build (and vice versa), but bundling them in one release means users get a tested pair.
- **No 200 MB tarballs in source repos.** Build artifacts in release attachments, not in git history.
