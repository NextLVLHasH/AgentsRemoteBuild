# AgentsRemoteBuild

Build infrastructure for the **LM Link with YaRN** runtime — a YaRN-capable `llama-server` package consumed by the [Agents](https://github.com/NextLVLHasH/Agents) coder app and by [Linux-Install-Scripts/installstart.sh](https://github.com/NextLVLHasH/Linux-Install-Scripts/blob/main/installstart.sh) on RunPod pods.

This repo:

- **Builds** `llama-server` from `ggml-org/llama.cpp` with CUDA 12 + shared libs + YaRN support enabled.
- **Packages** it (binary + libs + drop-in LM Studio overlay + README) into a single tarball.
- **Publishes** it as a GitHub release so any Linux pod can `curl` the prebuilt instead of waiting on a 3-5 minute source compile.

## Workflow

```
┌──────────────────┐    builds      ┌───────────────────────────┐    publishes    ┌────────────────────┐
│  WSL / Linux box │ ─────────────▶ │ release/lm-link-yarn-*.tgz│ ──────────────▶ │ NextLVLHasH/       │
│ build-release.sh │                │ + .sha256 + README        │ gh release ...  │ AgentsRemoteBuild  │
└──────────────────┘                └───────────────────────────┘                 │ Releases           │
                                                                                  └─────────┬──────────┘
                                                                                            │ curl
                                                                                            ▼
                                                                                  ┌────────────────────┐
                                                                                  │ RunPod pod         │
                                                                                  │ installstart.sh    │
                                                                                  │   uses prebuilt    │
                                                                                  └────────────────────┘
```

## Building a release locally

Need: Linux x86_64 (or WSL2 with the NVIDIA WSL driver), CUDA 12 toolkit, ~10 GB free disk for the build tree.

```
chmod +x build-release.sh
./build-release.sh
```

Output lands in `release/lm-link-yarn-<sha>-linux-x64-cuda12.tar.gz` plus a `.sha256` and a `README.md`.

To pin a specific llama.cpp commit or tag (recommended for reproducible releases):

```
LLAMA_REF=b4500 ./build-release.sh
```

## Publishing a release

```
cd release
gh release create v0.1.0 lm-link-yarn-*.tar.gz lm-link-yarn-*.sha256 \
  --repo NextLVLHasH/AgentsRemoteBuild \
  --notes-file README.md \
  --title "LM Link with YaRN — llama.cpp $(date +%Y-%m-%d)"
```

Once released, the asset is available at:

```
https://github.com/NextLVLHasH/AgentsRemoteBuild/releases/latest/download/lm-link-yarn-<sha>-linux-x64-cuda12.tar.gz
```

Or via the GitHub API (used by `pull-on-pod.sh`):

```
https://api.github.com/repos/NextLVLHasH/AgentsRemoteBuild/releases/latest
```

## Pulling on a pod

Use [pull-on-pod.sh](pull-on-pod.sh) inside any RunPod pod (or local Linux box) to fetch the latest release and stage it for `llama-server`:

```
curl -fsSL https://raw.githubusercontent.com/NextLVLHasH/AgentsRemoteBuild/main/pull-on-pod.sh | bash
```

That drops the binary at `/workspace/llama.cpp-prebuilt/llama-server` and sets up `LD_LIBRARY_PATH` so the bundled `.so` files resolve. `installstart.sh` checks this location before falling back to a source build.

## What goes in a release tarball

```
lm-link-yarn-<sha>-linux-x64-cuda12/
├── bin/llama-server                # the CUDA-enabled HTTP server
├── lib/libllama.so                 # llama.cpp runtime
├── lib/libggml*.so                 # ggml backends (cpu, cuda, base)
├── run-llama-server                # wrapper that sets LD_LIBRARY_PATH
├── install-into-lmstudio.sh        # overlay into LM Studio's bundled runtime
└── README.md
```

## Why a separate repo

- **Builds are slow.** Source builds inside `installstart.sh` take 3-5 min per cold pod start. Publishing a binary once lets every downstream pod skip that.
- **Release cadence is separate from `Agents`.** Bumping the `Agents` app version shouldn't force a new llama.cpp build; bumping llama.cpp shouldn't force an Agents tag.
- **Binary artifacts don't belong in source repos.** A 200 MB tarball in `Agents` would bloat the clone for every contributor. Releases on a build-dedicated repo keep `Agents` lightweight.
