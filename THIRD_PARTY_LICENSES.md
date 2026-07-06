# Third-Party Licenses

Local Vision builds on outstanding open-source work. Thank you to every author below.

## Vendored source code (compiled into the app, `Vendor/Kokoro`)

| Project | Author | License | Source |
|---------|--------|---------|--------|
| kokoro-ios (KokoroSwift TTS engine) | Adrian Murray | MIT | https://github.com/adriancmurray/kokoro-ios |
| MisakiSwift (English G2P) | mlalma | Apache-2.0 | https://github.com/mlalma/MisakiSwift |
| MLXUtilsLibrary | mlalma | Apache-2.0 | https://github.com/mlalma/MLXUtilsLibrary |

The vendored sources retain their original copyright. Local modifications are
limited to build integration (module flattening, resource loading paths) and
are documented in the repository history.

## Swift package dependencies

| Package | License | Source |
|---------|---------|--------|
| mlx-swift | MIT | https://github.com/ml-explore/mlx-swift |
| mlx-swift-examples (MLXVLM/MLXLLM) | MIT | https://github.com/ml-explore/mlx-swift-examples |
| SwiftWhisper (whisper.cpp) | MIT | https://github.com/exPHAT/SwiftWhisper |
| ZIPFoundation | MIT | https://github.com/weichsel/ZIPFoundation |

## Models (downloaded at runtime, not distributed with this repository)

| Model | License | Source |
|-------|---------|--------|
| SmolVLM2-500M-Video-Instruct | Apache-2.0 | https://huggingface.co/HuggingFaceTB/SmolVLM2-500M-Video-Instruct |
| Whisper (ggml base.en) | MIT | https://huggingface.co/ggerganov/whisper.cpp |
| Kokoro-82M | Apache-2.0 | https://huggingface.co/hexgrad/Kokoro-82M (MLX conversion: prince-canuma/Kokoro-82M) |
