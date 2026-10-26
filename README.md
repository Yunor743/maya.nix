# maya.nix

Run [Project Maya](https://github.com/mw00/project-maya) as a native NixOS service, with an
OpenAI- and Anthropic-compatible API on localhost. Its engine serves **GLM-5.3-Flash** (a
321 B-parameter MoE, ~18 B active) on your own NVIDIA GPU(s). Ported from the same shape as
[strata.nix](https://github.com/Yunor743/strata.nix).

```
┌─────────────┐   OpenAI/Anthropic    ┌──────────────┐   stdin/stdout   ┌────────────────────┐
│ your apps   │ ────  HTTP  API  ───▶ │  maya-serve  │ ───────────────▶ │ strata engine      │
│ / web chat  │   http://127.0.0.1    │  (python)    │                  │ (CUDA, built from  │
└─────────────┘                       └──────────────┘                  │  source)           │
                                                                        └────────────────────┘
   weights: downloaded once (resumable, sha256-verified) into /var/lib/maya, not in the nix store
   images: strata-vision (llama.cpp's mtmd + Maya's vision tower), started only while it encodes
```

## Requirements

- NixOS on **x86_64-linux** with an NVIDIA GPU of compute capability 7.5 or newer (RTX 20 and newer) and
  the official driver. About 32 GB of RAM minimum; more RAM keeps more experts close and is faster.
  A Volta V100 (sm_70) needs `cudaArch = "70"` and a one-line relaxation of upstream's CMake arch guard.
- ~100 GB of free disk **on a fast NVMe SSD** for the model files (Maya-S24 is 94.7 GB, Maya-L 156.3 GB),
  plus 1.1 GB for the picture encoder. A spinning disk makes the expert streaming slow.
- The CPU needs AVX2; the AVX-512 expert kernels are used when the CPU has them.

## Quick start

```nix
# flake.nix of your system
{
  inputs.maya-nix.url = "github:Yunor743/maya.nix";   # adjust to wherever you publish this repo
  # ...
  outputs = { self, nixpkgs, maya-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        maya-nix.nixosModules.default
        {
          services.maya.enable = true;
          # defaults: Maya-S24, 32K context, API on 127.0.0.1:8080
        };
      ];
    };
  };
}
```

The service, on its first start:

1. downloads the quant's shards and the vision files from Hugging Face. The download is resumable and
   every file is checked against the sha256 upstream publishes for it, so an interrupted start
   continues where it left off;
2. builds the pack (the engine's index of the model files) inside the model folder with upstream's own
   builder (`tools/iq_pack.py --compat-bf16`), and copies the shipped expert profile;
3. writes `/var/lib/maya/config.json` (engine arguments, tokenizer, API key if any, the vision block);
4. starts `maya-serve` on `http://127.0.0.1:8080`.

While the model loads (tens of GB into RAM, most of it pinned) the machine can be slow for a few minutes:
that is normal. API: `http://127.0.0.1:8080/v1/chat/completions` (OpenAI) and `/v1/messages` (Anthropic).
Chat and Monitor in the browser: `http://127.0.0.1:8080/`.

## Options (`services.maya.*`)

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Enable the service. |
| `package` | `mayaPkgs.maya` | The maya-serve bundle (carries the engine and the encoder). |
| `quant` | `Maya-S24` | `Maya-S-v2-IQ2_XXS` / `Maya-S24` / `Maya-M` / `Maya-M-Derisked` / `Maya-L`. |
| `context` | `32768` | 8192–1048576 tokens. The KV cache streams from RAM above the resident window. |
| `host` / `port` | `127.0.0.1` / `8080` | Listen address. |
| `apiKeyFile` | `null` | Path to a file with the API key (systemd credential). Required when `host` is not loopback. |
| `hfTokenFile` | `null` | Hugging Face token file, only for gated repos. |
| `openFirewall` | `false` | Open the TCP port in the firewall. |
| `gpus` | `[ ]` | CUDA device indices; several = layer split. Empty: the card with the most VRAM. |
| `layerSplit` | `"auto"` | Where the layer split cuts when `gpus` names several cards. |
| `parallel` | `null` | Several requests answered at once (1–8); each keeps its own context in VRAM. |
| `draft` | `mtp` | `mtp` (the quant's own block) or `dflash2` (downloaded drafter, CC BY-NC-ND 4.0). |
| `vision` | `true` | Images: the encoder runs in GPU memory the model lends it. False: text only. |
| `kvStreaming` | `"on"` | Keep the attention cache in RAM with a VRAM window, so VRAM holds more experts. |
| `prefill` | `"auto"` | Prompt chunk; a number such as `"32768"` sets it itself. |
| `sampling` | `{ }` | Sampling defaults (temperature, top_p, ...). Upstream: 1.0 / 0.95. |
| `mcpServers` | `{ }` | MCP servers for the web chat (Claude Desktop format; they run with the service's rights). |
| `env` | `{ }` | Engine environment (`STRATA_GLM_*`: RAM headroom, CPU lane, prompt sub-batches ...). |
| `extraEngineArgs` | `[ ]` | Extra engine arguments, e.g. `[ "--kv" "q4_0" ]`. |
| `mockEngine` | `false` | Scripted mock instead of the model (tests; no GPU, no download). |
| `prefetchOnStart` | `true` | Download/prepare missing files before starting (resumable, skipped when done). |

Example: the compact quant on a 24 GB card, two requests at once, a LAN-reachable API:

```nix
services.maya = {
  enable = true;
  quant = "Maya-S24";
  context = 32768;
  parallel = 2;
  host = "0.0.0.0";
  port = 8080;
  apiKeyFile = "/run/secrets/maya-api-key";
  gpus = [ "0" ];
  env = { STRATA_GLM_RAM_HEADROOM_GB = "10"; };
};
```

## Packages

- `maya` (same as `maya-serve`): the server bundle, `maya-serve`, `maya-chat` and `maya-prefetch` (the
  download/prepare tool, usable standalone; `maya-prefetch --help`).
- `maya-engine`: the CUDA inference binary, built from source
  (`maya-engine.override { cudaArch = "120"; }` for an RTX 50 card; default `89` = RTX 40).
- `maya-vision`: the image encoder, llama.cpp's mtmd at the pinned commit with Maya's GLM-5.3-Flash
  vision tower applied by `tools/vision/glm5next_patch.py`.
- The model weights are **not** packaged: they are downloaded at runtime into the service's state
  directory (the nix store would not survive a 100 GB model well).

## How the engine is built

`maya-engine` compiles the pinned Project Maya source with nixpkgs' CUDA toolchain
(`backendStdenv`, CUDA 12.9) against the llama.cpp commit pinned in Maya's `third_party/ggml/VERSION.txt`
(passed as `-DSTRATA_GGML_DIR`; upstream's published tree ships only the licences and the patch there).
The build needs `git`: CMake applies `third_party/ggml/mmq-fused-swiglu.patch` to a copy of that checkout.

If Maya bumps its pin, evaluation fails with the new commit and an instruction to update the
`llama-pinned` input. The flake input `maya` tracks upstream `main`. The lock file decides what you
actually run: `nix flake lock --update-input maya` pulls new releases; audit what lands in it before doing so.

## Testing

- `nix flake check`: a serve smoke test (mock engine, HTTP endpoints without a GPU) and a NixOS VM test
  of the systemd service with the mock engine.
- `nix build .#maya-engine`: the real compile (20-40 minutes, once, cached after).
- `nix build .#maya-vision`: the encoder build (llama.cpp's mtmd + ggml's CUDA kernels).

## Notes for this port

- The dashboard's **About > Update** cannot work in the store (it does a `git pull` on the checkout);
  update by bumping the flake input instead. The interactive installer (`./maya.sh`) is not what the
  service runs: the service uses `maya-serve` + `maya-prefetch`, which is also why nothing is written
  outside the state directory.
- EXL3 quants (turboderp's, read in place from their safetensors) are not driven by `maya-prefetch`;
  put their files in a folder and use upstream's own packer, or keep them for the non-Nix install.
- `draft = "dflash2"` downloads a drafter under CC BY-NC-ND 4.0 (non-commercial only), pinned to the
  revision upstream measured it on. It only pays off when most of the model is close, so measure it.
- The engine pins nearly all free RAM for its expert tier; other services get little while Maya runs.
- If the engine (or the vision encoder) logs `CUDA driver is a stub library`, something put the CUDA
  toolkit's stub `libcuda.so.1` on the loader path ahead of the real driver. An inherited
  `LD_LIBRARY_PATH` is the usual culprit. The binaries' RUNPATH already starts with
  `/run/opengl-driver/lib`, so the systemd service is unaffected; clear `LD_LIBRARY_PATH`
  (or set it to `/run/opengl-driver/lib`) for manual runs.

## Licenses

- This flake: MIT.
- Project Maya (engine, server, tools): MIT, upstream <https://github.com/mw00/project-maya>, whose own
  notices (Strata, ggml/llama.cpp, exllamav3, beellama.cpp) stay with every copy.
- The model weights are not part of this flake; each model's licence applies (GLM-5.3-Flash by zai-org:
  MIT; the optional DFlash2 drafter: CC BY-NC-ND 4.0).
