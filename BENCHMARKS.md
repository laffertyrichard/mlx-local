# Local Benchmark and Smoke Results

Machine: Mac mini Mac16,11, Apple M4 Pro, 64 GiB unified memory. The router consumes the machine-readable records in `Benchmarks/local-results.json`; this document explains their provenance and the end-to-end smoke results.

## Capability measurements

| Model | Capability | Quality signal | Speed / latency | Peak memory | Notes |
|---|---|---:|---:|---:|---|
| `olmOCR-7B-0725-8bit` | OCR | fact F1 .6748; numeric F1 .6460 | ~30 tok/s | ~10.67 GB | Best numeric reliability in prior 30/60-doc local suites |
| `dots.ocr-8bit` | OCR | fact F1 .6581; numeric F1 .6087 | ~110 tok/s | ~6.02 GB | Faster/smaller; two malformed/repetition cases in 15-doc run |
| `Qwen3-VL-8B-Instruct-4bit` | vision | room-label recall .643 | 10.9 s prior dense-plan task | ~7.22 GB | Better local route than the tested 30B for this task |
| `Qwen3-VL-30B-A3B-Instruct-4bit` | vision | room-label recall .571 | ~30 s / looped to cap | ~19.57 GB | Bigger was not better on dense plans |
| `Qwen3.6-35B-A3B-4bit` | chat/code | cleanup .965; code .943 | ~55 tok/s | model-specific | Balanced compiler/reasoner candidate |
| `Qwen3-30B-A3B-Instruct-2507-4bit` | chat | cleanup .965 | ~61 tok/s | model-specific | Fast general model |
| `Huihui-Qwen3.6-27B-abliterated-4.5bit-msq` | code/reasoning | code .971; cleanup .937 | ~25 tok/s | model-specific | Preserved V1 preference; weaker instruction hierarchy risk |
| `Qwen3-ASR-0.6B-8bit` | speech-to-text | 1.0 expected-term recall | 0.19 s generation | 1.81 GB | Exact transcript on local synthetic meeting recording |

Public reputation is not used as the sole preference. Failure/malformed counts and local task quality affect scoring. Missing first-token measurements remain absent rather than estimated.

## Fresh end-to-end product smoke results

These used `MultimodalSmoke`, the same classifier/router/resource manager/backend adapters as the app.

### One image

Route: `Qwen3-VL-8B`
Load: 2.81 s; stage: 11.61 s.
Result correctly read `ROOM A`, `12'-6" × 10'-0"`.

### Scanned PDF

Route: native PDF render → `olmOCR-7B` → `Huihui-Qwen3.6-27B`.
Stages: 0.11 s render, 11.42 s OCR, 75.36 s reasoning.
Result correctly extracted the room and dimensions and explained imperial notation.
A second structured run used the same OCR intermediate and terminal JSON validation, producing `{"rooms":[{"name":"ROOM A","dimensions":"12'-6\" x 10'-0\""}]}`. This specifically verifies that final JSON requirements do not poison the OCR stage.

### Audio summary

Route: `Qwen3-ASR-0.6B` → `Huihui-Qwen3.6-27B`.
Stages: 0.214 s transcription, 41.16 s reasoning.
Result correctly reported Tuesday, $42,000, and Alice's final-report action.

### Code attachment

Route: `Qwen3-Coder-30B-A3B`.
Load: 0.68 s; stage: 12.52 s.
The model received the attached Python file, identified `ZeroDivisionError`, and supplied guarded fixes.

### Multiple images

The direct baseline correctly read both room names/dimensions, but made an unsolicited area arithmetic error (`12.5 × 10` described as 126). The adversarial review converted this class of task to multi-image extraction → text reasoning → validation. The fresh route ran in 27.90 s + 94.16 s + 145.18 s and explicitly corrected `12.5 × 10 = 125 sq ft` while preserving both source dimensions. This improves correctness but exposes a substantial validation-latency target for V3. It is an example of local product evidence changing routing policy instead of relying on parameter count or reputation.

## Repeatability

```bash
./scripts/generate_benchmark_fixtures.py
./scripts/benchmark.py --model mlx-community/Qwen3-ASR-0.6B-8bit --capability speech_to_text
./scripts/benchmark.py --model mlx-community/Qwen3-VL-8B-Instruct-4bit --capability vision
swift run MultimodalSmoke Benchmarks/fixtures/scanned-plan.pdf \
  'Extract every room dimension from this scanned plan and explain the result.'
```

The benchmark runner records success quality, total latency, tokens/sec and peak memory when trustworthy backend output exposes them, failures, and malformed output. It can update `local-results.json`, which is copied into the installed app and merged into the registry.

## Caveats

The gold tasks are intentionally small and several text results are single runs. The OCR set is construction-document-heavy. Results should be refreshed after backend/model/macOS upgrades. Visual arithmetic and cross-page completeness need larger gold sets; diarization and natural noisy audio are not yet covered.
