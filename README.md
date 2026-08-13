# MLX Local

MLX Local contains MLX Menu, a native macOS menu-bar application that routes private local inference across cached MLX language, vision/OCR, and speech models.

A user can submit text, code, images, multiple images, PDFs/documents, scanned PDFs, or audio. In **Auto** mode MLX Menu classifies the task, derives required capabilities, and chooses either one compatible model or a sequential local pipeline. **Manual** mode preserves the V1 model picker and streaming OpenAI-compatible chat server.

Everything runs locally. Workers bind only to `127.0.0.1`; no cloud provider is configured.

V3 preserves Manual/V1 and the V2 router while adding reversible evaluated Model Profiles, validity-bound checkpoint resume, persisted stage telemetry, deterministic claim validation, and a narrow permissioned workflow contract. Prime/workflow orchestration remains separate from model routing. See [`V3/README.md`](V3/README.md) for reproducible evidence and the measured hybrid-boundary ADR.

## What works

| Input | Typical route |
|---|---|
| Text/chat/reasoning | MLX-LM model |
| Code or traceback | coding-capable MLX-LM model |
| One image | MLX-VLM vision model |
| Multiple images | multi-image-capable MLX-VLM model |
| Text PDF/document | native text extraction → reasoning model |
| Scanned PDF | native page rendering → per-page OCR → reasoning model |
| Audio | MLX-Audio speech-to-text → reasoning/summarization model |
| Structured extraction | compatible model/pipeline → JSON validation → one retry → fallback |

Drag files into the chat window or use the paperclip. The compact header shows `AUTO` and the selected stage types; **Route details** exposes the detected task, required capabilities, selected models, reason, events, fallbacks, and intermediate artifacts.

## Install

### Team package

Build the macOS 14+ Apple-silicon installer and verify its payload without installing it:

```bash
./scripts/build-package.sh
# dist/MLX-Menu-3.1.1.5.pkg
# dist/MLX-Menu-3.1.1.5.pkg.sha256
```

The package installs `MLX Menu.app` into `/Applications`. It deliberately contains no
privileged install scripts, does not add a login item, and does not download Python
runtimes or model weights. Recipients should install the backends they need first:

```bash
uv tool install mlx-lm
uv tool install mlx-vlm
uv tool install 'mlx-audio[server]'
```

A default local build is ad-hoc app-signed and the installer is unsigned, which is useful
for package testing but triggers Gatekeeper on another Mac. For normal team distribution,
build with Developer ID identities and a stored notary profile:

```bash
CODESIGN_IDENTITY='Developer ID Application: …' \
INSTALLER_IDENTITY='Developer ID Installer: …' \
NOTARY_PROFILE='mlx-menu-notary' \
./scripts/build-package.sh
```

See [`docs/package-distribution.md`](docs/package-distribution.md) for signing,
notarization, recipient verification, upgrades, and the clean-Mac acceptance checklist.

### Install from source

```bash
./scripts/install.sh                    # installs to ~/Applications and adds a LaunchAgent
./scripts/install.sh --no-launch-at-login
```

The source installer and package builder share `scripts/build-app.sh`, so both ship the
same executable, resources, version, and bundle metadata.

Inference always runs offline (`HF_HUB_OFFLINE=1`). The menu-bar panel has a separate, explicit **Download Model** field for Hugging Face `owner/repository` IDs. Downloads can be cancelled, completed models appear immediately in Manual mode, and each cached row has a confirmed remove action. Auto mode refreshes its registry after the app restarts.

Cached weights use disk space; they do not all stay resident in memory. Only running Manual/Auto workers load model weights into unified memory. Use **Stop Server** or quit MLX Menu to release that memory without deleting cached weights.

## V1 Manual mode

1. Choose a cached model with the explicit **Model** selector in the menu-bar panel (or the selector in the Manual chat header). The proven list includes `mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit`.
2. Select **Start Server**.
3. The V1 endpoint remains `http://127.0.0.1:8081/v1`. Use the numeric loopback address—not `localhost`—when another service (such as Docker) also publishes port 8081 over IPv6.
4. Open Chat and select **Manual** for the original streaming chat path.

Commands remain: `clear`, `/clear`, `/reset`, `/model`, `/stop`, `/help`, and Control-L.

## Auto mode

Auto mode uses normalized requests and capability metadata—not a model-name switch statement. Deterministic MIME/extension/attachment rules handle obvious requests. An optional `SemanticTaskClassifying` protocol is used only for low-confidence text classification. Routing then:

1. filters out incompatible/unhealthy models;
2. checks context and structured-output requirements;
3. scores local benchmark quality, speed, failure rate, memory, load cost, and residency;
4. creates a single-model or typed multi-stage route;
5. executes under the centralized lifecycle manager;
6. validates structured output and records fallbacks/actual execution path.

Manual attachment requests still use the pipeline executor but force the selected model after capability checks. An incompatible forced model fails explicitly rather than silently changing models.

## Local model registry

Discovery reads cached model configs and merges extensible metadata from `ModelMetadata/capabilities.json` plus measurements from `Benchmarks/local-results.json`. Per-model metadata can be changed without editing routing policy. At runtime an inspectable snapshot is written to:

```text
~/Library/Application Support/MLXMenu/registry.json
```

The registry records backend, family, quantization, capabilities, modalities, memory estimate, context, load/generation measurements, structured/tool/multi-image support, strengths/weaknesses, health, residency state, and capability benchmarks.

## Persistence and diagnostics

- V1 server log: `~/Library/Logs/MLXMenu/server.log`
- Auto worker logs: `~/Library/Logs/MLXMenu/workers/`
- Audio worker log: `~/Library/Logs/MLXMenu/audio-server.log`
- Registry: `~/Library/Application Support/MLXMenu/registry.json`
- Job traces/artifacts/failures: `~/Library/Application Support/MLXMenu/jobs/<request-id>/`

The most recent successful trace is restored after application restart.

## Build and evaluate

```bash
swift test
./scripts/test.sh
```

Swift Testing covers cache-management safety and incomplete-download discovery. `RouterEvaluation` remains the framework-independent orchestration suite; it covers deterministic and ambiguous classification, adversarial image/OCR distinctions, capability matching, Auto scoring, Manual override, unavailable/incompatible models, unsupported modalities, insufficient memory, document pipelines, fallback, malformed JSON, idle unloading, and manager restart.

Exercise the actual installed backends:

```bash
./scripts/generate_benchmark_fixtures.py
swift run MultimodalSmoke Benchmarks/fixtures/room.png \
  'Read the room label and dimensions.'
swift run MultimodalSmoke Benchmarks/fixtures/scanned-plan.pdf \
  'Extract every room dimension from this scanned plan and explain the result.'
swift run MultimodalSmoke Benchmarks/fixtures/meeting.wav \
  'Summarize this meeting recording.'
```

## Benchmarking

Representative tasks live in `Benchmarks/tasks.json`. Generate deterministic local fixtures, then benchmark one model/capability:

```bash
./scripts/generate_benchmark_fixtures.py
./scripts/benchmark.py --model mlx-community/Qwen3-VL-8B-Instruct-4bit --capability vision
./scripts/benchmark.py --model mlx-community/Qwen3-ASR-0.6B-8bit --capability speech_to_text
```

Use `--all` for every compatible task (expensive) and `--no-save` for a trial. Results include quality, total latency, generation speed where emitted by the backend, peak memory where emitted, failures, and malformed output counts. First-token latency remains `null` when a backend CLI does not expose a trustworthy token timestamp rather than fabricating a value.

See [ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries and backend rationale, [INSTALLED-MODELS.md](INSTALLED-MODELS.md) for the final local registry, [BENCHMARKS.md](BENCHMARKS.md) for measured results, and [MODEL-GUIDE.md](MODEL-GUIDE.md) for this Mac's operating envelope.

## Current limits

- PDF jobs are capped explicitly at 250 pages; OCR is sequential per page to avoid multi-image misuse and memory spikes.
- DOC/DOCX/RTF extraction uses native attributed-string support; unusual formats fail explicitly.
- Speech transcription is tested, but diarization, live microphone streaming, and audio-event understanding are not yet benchmarked.
- Deterministic evidence runs first; low-confidence text uses Apple NaturalLanguage sentence embeddings locally. More domain-specific semantic labels still need evaluation.
- Memory decisions use cached size plus measured peaks where available; macOS unified-memory pressure is not yet sampled continuously.
- V1 streams tokens. Auto pipelines currently stream stage status and expose artifacts, then publish each completed stage response rather than token-level output.
- This source export has no `.git` directory, so logical milestone commits could not be created here.
