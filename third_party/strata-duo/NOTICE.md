# Strata Duo (this fork)

This branch adds Strata Duo to Strata: one DeepSeek V4.1 Flash model split by layers over two Apple Silicon Macs.
Documentation: `docs/DUO.md`.

What belongs to it: `src/dsv41/ds4_duo.hpp`, the changes marked "Strata Duo" in `src/dsv41/ds4_model.cu`,
`src/dsv41/ds4_main.cpp` and `src/dsv41/ds4_model.hpp`, the `STRATA_DUO_TLS` block of `metal/CMakeLists.txt`, the
`duo/` directory, `docs/DUO.md` and `docs/DUO.zh-CN.md`. `git diff c5ab5d4` shows all of it (c5ab5d4 is the upstream
commit the branch starts from: Strata app 0.2.10, engine 0.1.56).

- Based on Strata, Copyright (c) 2026 Niko1221 and the Strata contributors, MIT License (`LICENSE` in the
  repository root). The Duo changes are offered under the same licence.
- The two-host idea and the design of the TLS transport (TLS 1.3 with a private CA and the role certificates
  `strata-stage-worker` / `strata-stage-coordinator`) follow the Linux/CUDA stage-RPC fork by petria,
  https://github.com/petria/Strata, branch `rpc-v0.2.13`, which is itself a fork of Strata under the same MIT
  licence. Its transport was used as the reference for the Duo link.
- The multi-host request upstream is Strata issue #5298.
- The Duo code was written with an AI coding assistant and tested on two Mac Studio M5 Ultra (96 GB each) connected
  by a Thunderbolt 5 cable.

Third-party software the Duo build downloads and links, each under its own licence: OpenSSL 3 (Apache License 2.0,
linked statically into `strata_ds4` when built with `-DSTRATA_DUO_TLS=ON`), Apple's metal-cpp headers and
llama.cpp's ggml (as in upstream Strata's Metal build).
