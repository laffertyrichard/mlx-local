# V3 Model Profile Optimization Report

## Method

A Model Profile is the deployable unit: base weights, system/task prompts, preprocessing version, generation limits, optional adapter reference, and backend options. `ModelProfiles.swift` provides versioning, deterministic configuration digests, held-out evidence gates, promotion, rollback, and Pareto-aware selection. The app loads `V3/model-profiles.json` (bundled at install) without model-name branches in routing code.

The prompt was frozen before evaluating new synthetic fixtures. When the first held-out set exposed a schema-shape issue, that set was explicitly moved to development; a generic non-semantic normalizer contract was frozen, then new E/F fixtures became held-out. This prevents relabeling contaminated examples as held-out. Full timestamps, raw outputs, fixture/model-config hashes, scores, and gold are in the definition/results JSON. `scripts/v3_profile_experiment.py` is the reproducible scorer/runner; `scripts/v3_verify_profile_results.py` re-scores saved raw runs and verifies fixture/model/scorer hashes. Registry evidence is bound to its evidence digest and requires two independent cases.

## Real local results

All runs used `mlx_vlm.generate`, temperature 0, 256 output tokens, two images, serial execution, and cached local weights. Each case scores six claims (exact label, dimensions, and area for each image).

| Profile | Development | Fresh held-out | Median total | Unsupported claims (all cases) | Failures |
|---|---:|---:|---:|---:|---:|
| Qwen3-VL 8B construction JSON | 0.917 | 0.750 | 10,098 ms | 4 unsupported claims | 0 |
| Qwen3-VL 30B construction JSON | **1.000** | **1.000** | 12,196 ms | **0 unsupported claims** | 0 |

The 8B model duplicated label tokens and also emitted wrong dimension ordering/arithmetic. The 30B profile was exact on development and two independent unseen held-out cases. Its quality advantage justifies the measured latency increase for quality-critical construction comparison. Speed and quality remain separate metrics; the sample is too small for broad statistical claims.

`qwen3-vl-30b-construction-json@1` is CURRENT and the 8B profile is RETIRED/reversible. Routing uses held-out profile evidence per task class before attaching the profile; Manual forced-model behavior is unchanged.

## Pipeline optimization

The old comparison path spent about 267 seconds across extraction, synthesis, and another unconstrained validation generation. V3 uses bounded profile output plus `DeterministicClaimValidator`: normalize the narrow room schema, verify/correct arithmetic, retain source URLs and uncertainty, and abstain to the existing LLM validator when structure/coverage is insufficient. The real tracer completed initial extraction/checkpoint/interruption in under one minute and resumed validation in 0.44 ms without reloading the model. This is not directly comparable to the old prompt/model run, but materially removes redundant validation generation.

## Adapter decision

**Not justified.** Prompting, deterministic schema/arithmetic handling, and evaluated profile selection solved the observed task. The corpus is tiny and recurring evidence is insufficient for training. Reconsider only after larger development data shows a stable weakness after cheaper knobs plateau; never train or tune on held-out answers.

Unavailable metrics (truthfully unknown): TTFT for non-streaming generation and exact Metal/KV-cache peak. Process RSS is not substituted.
