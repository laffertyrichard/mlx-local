# MLX Menu V3 — Detailed Work Summary

**Completed:** 2026-08-09
**Repository:** `/Users/mccully/projects/prime-agent-claude`
**Final implementation commits:** `99f8da8`, `ac552de` (on top of baseline `9505f74`)

## 1. Objective and invariants

V3 evolved the stable V2 local inference router rather than rewriting it. The implementation preserved these invariants throughout:

- Manual mode and V1 endpoint/SSE compatibility;
- deterministic capability routing and inspectable fallback;
- local execution by default with no silent cloud path;
- no model-name branches in routing policy;
- reversible experiments and profiles;
- explicit TRAIN/development/held-out separation;
- evidence-based boundary selection and profile promotion;
- scoped, auditable workflow access rather than shell/filesystem primitives.

A reproducible V2 baseline was committed before behavioral changes in `V3/BASELINE.md` and `V3/baseline-v2.json`.

## 2. Model Profiles and optimization registry

`Sources/LocalLLMCore/ModelProfiles.swift` introduced:

- `ModelProfile` as the deployable unit: base model, task classes, capabilities, lifecycle, prompts/examples, preprocessing, generation controls, adapter reference, backend options, and creation metadata;
- deterministic canonical SHA-256 configuration digests;
- CURRENT / CANDIDATE / RETIRED lifecycle;
- versioned registry releases and non-destructive shipped/installed merges;
- typed experiment decisions and TRAIN/development/held-out splits;
- promotion gates requiring at least two independent held-out cases, bound evidence/scorer identifiers, non-regressing quality/failure/malformed metrics, and explicit `promote` decisions;
- rollback to a retired trusted profile;
- profile-aware Pareto scoring while retaining separate quality/latency dimensions.

The app bundles `V3/model-profiles.json`, migrates newer releases, preserves installed-only entries, quarantines corrupt registries, and writes the installed registry with mode 0600.

## 3. Real local profile experiments

The construction JSON prompt and normalizer contract were frozen before final held-out evaluation. When an earlier candidate set revealed a schema-shape issue, it was explicitly moved to development and a fresh held-out set was generated instead of reusing contaminated examples.

Eight raw real MLX-VLM runs compare:

- `qwen3-vl-8b-construction-json@1`
- `qwen3-vl-30b-construction-json@1`

Across development plus two independent fresh held-out cases:

| Profile | Development | Held-out | Median total | Unsupported claims |
|---|---:|---:|---:|---:|
| 8B | 0.917 | 0.750 | 10,098 ms | 4 |
| 30B | 1.000 | 1.000 | 12,196 ms | 0 |

The 8B profile duplicated labels and produced dimension/arithmetic errors. The 30B profile was promoted for quality-critical construction comparison. Adapter training was rejected because cheaper prompting, deterministic arithmetic, and profile selection had not plateaued on a corpus large enough to justify training.

Reproducibility artifacts:

- `V3/profile-experiment-definition.json`
- `V3/profile-experiment-results.json`
- `scripts/v3_profile_experiment.py`
- `scripts/v3_verify_profile_results.py`

The verifier binds the current frozen definition, scorer source, input fixtures, model configs, raw outputs, and scores. Final evidence digest: `82de7948c5f49d126716fa626403d6fca0ec64ac13e7cf207eccee35f7439194`.

## 4. Profile-aware runtime behavior

`CapabilityRouter` now accepts an optional `ModelProfileRegistry`, uses held-out task-specific profile evidence in scoring, and attaches a selected profile to each stage without changing existing calls.

`OpenAIWorkerRuntime` applies the selected profile's:

- system/task/few-shot prompt layers;
- generation temperature, max tokens, top-p/top-k, repetition penalty, and stop sequences;
- maximum image dimension.

Fallback correctness was hardened after review: if the actual fallback model does not match the preferred profile's base model, the runtime uses default configuration and telemetry records no profile rather than falsely attributing the preferred profile.

## 5. Checkpoint validity, integrity, and resume

`Sources/LocalLLMCore/ResourceManager.swift` now supports actual restart-safe resume.

A checkpoint context binds:

- request text and full conversation history;
- attachment canonical paths, modalities, MIME/extraction/page metadata;
- source path, length, and SHA-256 content digest;
- quality/latency/context/structured/local-only/forced-model settings;
- semantic stages, backends, capabilities, modalities, fallback list;
- profile configuration digests;
- pipeline, preprocessing, validator, and relevant configuration versions.

Every artifact is SHA-256 hashed in a chain anchored to the context digest and stage index. Resume rejects:

- legacy context-free checkpoints;
- changed request, history, source, route, profile, or configuration;
- source-content changes;
- artifact tampering;
- corrupt JSON;
- inconsistent completed-stage, artifact, model, or telemetry counts.

Execution starts at the first incomplete stage and emits `stageReused` events. Failed attempt time is retained in the checkpoint, while downtime between attempts is separated from cumulative active time and current-attempt wall time.

## 6. Reachable UI resume and retention

The first reliability review found that manager-level resume was unreachable from the app because every submission generated a new UUID. This was fixed by persisting the exact `InferenceRequest` beside the checkpoint and restoring incomplete jobs on app launch.

The chat UI now exposes:

- **Resume saved job** — resumes with the original request ID and saved decision;
- **Discard** — deletes persisted job and temporary inputs.

Completed/non-resumable/stale jobs clean temporary rendered inputs. Persistence is bounded to:

- 50 jobs;
- seven days;
- 1 GiB total.

Application Support/job directories use 0700 and structured files use 0600. Failure records are JSON and include whether cancellation was requested.

## 7. Telemetry

Persisted `StageTelemetry` / `ExecutionTelemetry` records include:

- requested and actual model IDs;
- actual profile ID;
- stage wall/load/inference timing;
- cumulative active, current-attempt, and end-to-end age;
- input/output tokens and throughput when exposed;
- estimated active memory and exact peak only when exposed;
- cache hit, retry, fallback, failure, and reuse state;
- cancellation state for terminal traces/failure records.

Unavailable fields remain nullable. The implementation explicitly lists queue latency, first-token latency, and exact Metal/KV memory as unknown rather than substituting misleading values.

## 8. Deterministic construction validation

`DeterministicClaimValidator` handles narrow construction dimensions/areas:

- structured JSON schema normalization;
- finite/bounded source index, label, dimension, area, and uncertainty checks;
- deterministic area recomputation/correction;
- unstructured dimension arithmetic when parseable;
- provenance metadata declaring `area_arithmetic_only` scope;
- conservative overall confidence;
- preservation of unrelated top-level schema fields.

After adversarial review, dispatch was changed from every `.validation` stage to an explicit `validationContract`. Generic multi-image and V1/V2 validations continue through the normal model validator.

## 9. HTTP, MCP, and hybrid architecture bakeoff

Three executable boundary candidates were measured with 30 iterations each using `scripts/v3_boundary_bakeoff.py`:

| Candidate | Median | p95 |
|---|---:|---:|
| HTTP | 16.94 ms | 43.40 ms |
| MCP | 16.53 ms | 40.08 ms |
| Hybrid | 16.36 ms | 37.70 ms |

The differences are not statistically meaningful enough to choose on latency. Hybrid won on the broader Pareto surface:

- preserves proven V1 HTTP/SSE inference;
- adds typed/discoverable MCP workflow tools;
- isolates workflow and inference failures;
- avoids wrapping all model traffic in an additional protocol;
- supports structured workflow provenance and permission metadata.

HTTP and MCP both denied `/etc/hosts`; process termination left the other boundary and V1 healthy. Details: `V3/ADR-001-HYBRID-BOUNDARY.md` and `V3/boundary-bakeoff.json`.

## 10. Permissioned workflow contract

`Sources/LocalLLMCore/V3Orchestration.swift` defines:

- versioned workflow descriptors and input/output schemas;
- capability, file-root, network, executable, confirmation, timeout, retry, idempotency, checkpoint, artifact, and resource declarations;
- a capability broker for bounded regular-file reads;
- `open(O_NOFOLLOW)` + `fstat` checks to reduce symlink races;
- 64 MiB per-file bounds and audited actual operations;
- JSONL audit logs with 0600 permissions;
- a narrow construction inventory workflow with no network/process broker;
- orchestration configuration/evaluation records;
- a design-only cloud escalation proposal with no execution path.

The contract is intentionally honest: trusted in-process Swift handlers still have ambient APIs, so this is not an OS sandbox. Any untrusted/third-party workflow must run in a killable, sandboxed child process. Cooperative timeout is not claimed as a hard kill.

Reference HTTP/MCP spikes add bearer/fixed-loopback constraints, frame/body/path/file/aggregate bounds, regular-file checks, and no-follow file opening. They are evidence adapters, not unrestricted production tools.

## 11. Construction Plan Intelligence tracer

`ConstructionTracer` and `scripts/v3_run_hybrid_tracer.py` prove the selected boundary using unseen `LOBBY E` and `OFFICE F` fixtures.

The run:

1. starts the MCP adapter;
2. inventories and hashes both scoped images;
3. confirms local V1 model control;
4. runs real local Qwen3-VL 30B extraction;
5. writes a checkpoint after the expensive stage;
6. deliberately cancels and shuts down the manager;
7. decodes the checkpoint from disk in a new manager;
8. reuses extraction and runs deterministic area validation;
9. verifies no model loaded after restart;
10. records exact result/provenance and cleans processes.

Accepted output:

- `LOBBY E`: 14 × 6.5 = 91 sq ft;
- `OFFICE F`: 10.25 × 9 = 92.25 sq ft;
- both uncertainty fields preserved;
- extraction reused;
- resume time 0.315 ms;
- no cloud fallback.

## 12. Review and remediation

Two independent initial adversarial reviews covered architecture/reliability and security/privacy/evaluation integrity. They found three High issues:

1. UI resume was unreachable;
2. construction validation was globally injected;
3. fallback models inherited the preferred model profile.

All three were fixed and regression-tested. Medium findings also drove:

- canonical history/source/config checkpoint hashing;
- chained artifact integrity;
- active-vs-downtime timing;
- failed-attempt telemetry;
- brokered workflow operations and explicit trust caveat;
- scoped validator confidence;
- bounded retention and secure file modes;
- profile registry migration;
- HTTP/MCP limits;
- two genuinely independent held-out cases and scorer-source evidence binding.

Two fresh independent fix reviews confirmed prior Highs resolved. A final review detected stale development gold in the experiment definition; dimensions were restored, all eight saved raw runs were re-scored, scorer source was bound, and the final evidence verifier passed.

## 13. Installation and operational verification

`scripts/install.sh` now:

- installs version 3.0.0 and bundles `model-profiles.json`;
- preserves whether V1 was running via `--start`;
- waits for launchd bootout and performs one bounded bootstrap retry after reproducing a transient label-retention failure.

Final live checks:

- app/LaunchAgent plist lint: passed;
- strict deep codesign: passed;
- LaunchAgent state: running with `--start`;
- bootout left no orphan worker;
- bootstrap restored health in 2.5 s;
- `/health`: 200;
- `/v1/models`: 200, 21 models;
- non-streaming completion: exact `FINAL V3 OK`, 1.157 s;
- SSE: exact `FINAL SSE OK`, first event 723 ms, total 866 ms, `[DONE]` received;
- no experimental listeners or MCP/tracer/VLM processes remained.

## 14. Verification commands

```bash
./scripts/test.sh
swift build -c debug
swift build -c release
python3 scripts/v3_verify_profile_results.py
python3 scripts/v3_boundary_bakeoff.py --iterations 30
python3 scripts/v3_run_hybrid_tracer.py
./scripts/install.sh
```

The final RouterEvaluation suite passed 46/46 checks. Do not use `swift test`; the package intentionally uses the executable evaluation harness because there is no XCTest target in this Command Line Tools environment.

## 15. Durable files and commits

Start at `V3/README.md` for the evidence index. The principal artifacts are:

- `V3/BASELINE.md`
- `V3/ADR-001-HYBRID-BOUNDARY.md`
- `V3/OPTIMIZATION-REPORT.md`
- `V3/PRIVACY-PERMISSIONS.md`
- `V3/TRACER-REPORT.md`
- `V3/model-profiles.json`
- `V3/profile-experiment-definition.json`
- `V3/profile-experiment-results.json`
- `V3/construction-tracer-result.json`

Commit chain:

- `9505f74` — baseline snapshot;
- `99f8da8` — V3 implementation;
- `ac552de` — V3 evidence and documentation.

## 16. Remaining limitations and safe next steps

The next iteration should be evidence-driven, not architectural churn:

1. Grow the construction corpus and independent held-out cases before broad accuracy claims.
2. Add backend-native TTFT and Metal/KV instrumentation.
3. Add MCP progress/cancellation only for a concrete workflow requiring it.
4. Use a sandboxed child process for any untrusted workflow implementation.
5. Consider encryption/user-configurable retention for sensitive job artifacts.
6. Preserve Manual/V1, deterministic routing, explicit profile evidence, and no-silent-cloud invariants in every future change.
