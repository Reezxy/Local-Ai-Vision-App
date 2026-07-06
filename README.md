<div align="center">

# 👁️ Local Vision

### Point your iPhone at anything. Ask. It sees, thinks, and talks back — **100% on-device.**

*A real-time AI vision assistant built with Apple MLX. No cloud. No API keys. No data ever leaves your phone.*

[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com)
[![MLX](https://img.shields.io/badge/Apple-MLX-0071e3?logo=apple&logoColor=white)](https://github.com/ml-explore/mlx-swift)
[![100% On-Device](https://img.shields.io/badge/inference-100%25%20on--device-34c759)](#-privacy)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#-contributing)

**vision-language-model · speech-to-text · text-to-speech — three local AI models, one seamless voice loop**

</div>

---

## ✨ What it does

Local Vision turns your iPhone camera into a conversational AI assistant, in the style of Apple Intelligence:

🎥 **Full-screen live camera** — the whole app is one viewfinder, with an animated Siri-style edge glow
🎙️ **Ask by voice or text** — push-to-talk (Whisper) or type
📸 **One frame per question** — the instant you ask, the current frame is captured and sent to the vision model
🧠 **SmolVLM2 answers** — short, spoken-friendly answers about whatever you're pointing at
🗣️ **Kokoro speaks** — a natural neural voice reads the answer aloud *while the rest is still generating*
✨ **Apple-Intelligence UI** — glowing screen border, shimmer status pills, Liquid Glass controls, conversation text rendered directly on the camera feed

```
you ask  →  Whisper transcribes  →  frame captured  →  SmolVLM2 reasons  →  Kokoro speaks
                              all locally, on the iPhone's GPU/ANE
```

## 🔒 Privacy

Everything runs **fully offline** after the one-time model download. Camera frames, your voice, and every answer are processed on the device's own silicon — nothing is uploaded, logged, or shared. Airplane mode? Still works.

## 🤖 The models

| Role | Model | Runtime | Size |
|------|-------|---------|------|
| 👁 Vision | [SmolVLM2-500M](https://huggingface.co/HuggingFaceTB/SmolVLM2-500M-Video-Instruct) | Apple MLX (GPU) | ~1 GB |
| 👂 Speech-to-text | [Whisper base.en](https://huggingface.co/ggerganov/whisper.cpp) | whisper.cpp (CPU/ANE via CoreML) | ~150 MB |
| 🗣 Text-to-speech | [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Apple MLX (GPU) | ~330 MB |

Models are downloaded on first launch with per-model progress, stored on device, and manageable (inspect / delete / re-download) from the in-app settings page. Every AI component sits behind a protocol — swapping a model is a one-line change in `AppEnvironment`.

> 💪 Have an 8 GB iPhone (15/16 Pro)? Swap the vision model to `mlx-community/Qwen3-VL-2B-Instruct-4bit` in `QwenVisionService` for noticeably stronger answers.

## ⚡ Engineering highlights

Things this repo solves that you'd otherwise learn the hard way:

- **Cooperative GPU interleaving** — TTS synthesis runs *synchronously on the LLM's generation thread* between token steps, so speech starts after the first sentence while the model keeps writing. Async GPU overlap stalls (MLX serializes), and the CPU device fatal-errors on iOS — this is the pattern that actually works.
- **Gapless sentence streaming** — sentence *N+1* synthesizes while *N* plays, buffers queued back-to-back on `AVAudioPlayerNode`. No robotic pauses.
- **The MLXNN duplicate-linking trap** — two SwiftPM packages consuming mlx-swift makes Xcode link MLXNN both statically *and* dynamically → duplicate Obj-C classes → mysterious inference crashes. Solved by vendoring the TTS engine into the app target (see `Vendor/Kokoro`).
- **Dependency-graph peace treaty** — mlx-swift-examples pinned to the last tag exporting MLXVLM, whisper.cpp instead of WhisperKit (transformers version conflict), all documented in `project.yml`.
- **Apple-Intelligence look in pure SwiftUI** — the rotating edge glow is three blurred `AngularGradient` strokes rasterized in a single Metal pass; the shimmer pills are a moving gradient mask. No private APIs.

## 🚀 Getting started

**Requirements:** Xcode 26+, iOS 18+, a physical iPhone (MLX needs the real GPU — the Simulator won't run inference), ~2 GB free storage. A free Apple ID is enough to sideload.

```bash
brew install xcodegen
git clone https://github.com/Reezxy/Local-Ai-Vision-App.git
cd Local-Ai-Vision-App
xcodegen generate
open LocalVision.xcodeproj
```

1. Set your team in **Signing & Capabilities** (or `DEVELOPMENT_TEAM` in `project.yml`)
2. Build & run on your iPhone
3. First launch downloads the three models (Wi-Fi recommended) — then you're fully offline

## 🏗 Architecture

```
Sources/
├── App/          AppEnvironment (composition root — swap models here)
├── Camera/       AVCaptureSession + single-frame capture
├── AI/
│   ├── Services/ Protocol-based: VisionLanguageService / SpeechToTextService / TextToSpeechService
│   ├── Pipeline/ VisionPipeline — the ask→capture→reason→speak loop
│   └── ModelDownloader — on-device model cache with atomic downloads
├── Audio/        16 kHz recorder (Whisper), gapless PCM player (Kokoro)
└── UI/           Full-screen camera, glow border, shimmer pills, Liquid Glass input
Vendor/
└── Kokoro/       Vendored MLX TTS engine (see THIRD_PARTY_LICENSES.md)
```

The core rule: **the vision model never sees a video stream.** One question = one frame, captured the moment you ask. That keeps context tiny, answers fast, and battery sane.

## 🗺 Roadmap

- [ ] Hands-free voice activation (VAD) — talk without holding the mic
- [ ] Voice picker (Kokoro ships 54 voices)
- [ ] Multi-turn visual conversations (follow-up questions about the same frame)
- [ ] Tab pages: history, settings
- [ ] iPad support

## 🤝 Contributing

PRs and issues are very welcome — especially around model performance, new model integrations, and UI polish. If you hit an MLX/dependency edge case, please open an issue: half this README's "engineering highlights" started as bug reports.

## 📄 License

[MIT](LICENSE) — model weights and vendored components under their own permissive licenses, see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

---

<div align="center">

**If this project helps you build on-device AI, a ⭐ means a lot.**

*Keywords: on-device AI · local LLM · vision language model · VLM · Apple MLX · mlx-swift · SmolVLM · Qwen-VL · Whisper · whisper.cpp · Kokoro TTS · speech-to-text · text-to-speech · iOS AI app · SwiftUI · Apple Intelligence style · offline AI assistant · edge AI · private AI · camera AI · multimodal*

</div>
