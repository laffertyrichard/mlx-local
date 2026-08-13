# MLX Menu V2 Architecture

## Design intent

MLX Menu V2 is a capability router, not a catalog of model-name branches. A normalized request declares modalities and product constraints; classification derives required capabilities; registry metadata states what local providers can do; a deterministic policy chooses a compatible route; the lifecycle manager admits and executes it.

Model-specific facts live in metadata and benchmark files. Routing code uses capabilities, health, resources, and measurements.

## Module boundaries

```text
SwiftUI / request ingestion
  └─ InferenceRequest + RequestAttachment + conversation history
       └─ TaskClassifier
            └─ TaskRequirements (category, capabilities, modalities, context)
                 └─ CapabilityRouter
                      ├─ ModelRegistry + local benchmarks
                      └─ MachineResources
                           └─ RoutingDecision / RouteStage[]
                                └─ ModelResourceManager
                                     ├─ NativeDocumentRuntime
                                     ├─ OpenAIWorkerRuntime (MLX-LM)
                                     ├─ OpenAIWorkerRuntime (MLX-VLM)
                                     └─ MLXAudioRuntime
                                          └─ artifacts, checkpoints, trace, UI
```

- `Sources/LocalLLMCore/RequestDomain.swift` — backend-neutral requests, capabilities, modalities, requirements.
- `TaskClassifier.swift` — deterministic evidence first; optional cheap semantic refinement.
- `ModelRegistry.swift` — discovery, metadata/profile overlays, benchmark merge, health/residency.
- `CapabilityRouter.swift` — pure filtering/scoring/pipeline policy; emits inspectable decisions.
- `ResourceManager.swift` — centralized load sharing, memory reservations, eviction, timeout, retries, fallback, JSON validation, checkpoints.
- `Sources/LocalInferenceBackends/` — backend adapters and local preprocessing. Product routing policy is absent here.
- `Sources/MLXMenu/` — lifecycle composition, persistence, and SwiftUI. The UI contains no scoring policy.

## Backend research and selection

Research and machine prototypes were performed against the installed M4 Pro / 64 GiB environment.

### Text: MLX-LM

Apple's maintained `ml-explore/mlx-lm` remains the V1-compatible text backend. V2 starts isolated loopback workers using the existing MPI/ring-safe launcher. It retains OpenAI-compatible internal chat semantics and the public V1 server at port 8081.

### Vision and OCR: MLX-VLM

`Blaizzy/mlx-vlm` is the maintained broad MLX vision implementation and supports the cached Qwen VL, olmOCR, and dots.ocr families. V2 uses its loopback server and OpenAI content parts. Images are decoded locally, resized to at most 4096 px on the longest side, normalized to PNG, and then transported to the worker. Scanned PDFs are rendered natively and OCR'd one page at a time; a model declaring no multi-image support is never handed a page batch.

### Speech: MLX-Audio

`Blaizzy/mlx-audio` was selected over older one-off `mlx-whisper` wrappers because it is maintained, exposes an OpenAI-compatible transcription endpoint, and supports current Whisper/Qwen3-ASR/Parakeet families. The installed `Qwen3-ASR-0.6B-8bit` produced an exact synthetic transcript in 0.19 s generation time at about 1.81 GB peak. Audio files are transcribed independently and normalized into one typed transcript artifact.

WhisperKit remains a good future native Swift alternative for live microphone UX; it is not required by V2.

### Documents: native PDFKit/AppKit

Extractable PDF text and supported rich-text documents are normalized locally before inference. Scanned pages are rasterized with PDFKit. This avoids asking a backend to consume a raw format it does not actually transport. Unsupported/unreadable documents fail instead of yielding prompt-only hallucinations.

### Semantic refinement: Apple NaturalLanguage

Obvious tasks are classified from MIME, extension, attachment count, extractable PDF text, and intent rules. Low-confidence text can be refined with Apple's local sentence embedding (`NLEmbedding`), avoiding a large reasoning-model load for classification.

## Registry extensibility

Discovery starts with Hugging Face cache configs. `ModelMetadata/capabilities.json` overlays facts that architecture configs cannot reveal (for example, an OCR-tuned Qwen-VL checkpoint). `Benchmarks/local-results.json` overlays local measurements. Adding or upgrading a model normally means adding metadata/measurements, not changing `CapabilityRouter`.

A runtime snapshot is persisted as JSON. Backend adapters are selected by the `InferenceBackend` field, so a future local provider—and eventually an optional cloud provider—can implement `ModelRuntime` without rewriting request/classifier/router contracts.

## Routing policy

Hard filters:

- health/availability;
- every required capability;
- normalized input modalities;
- context and structured-output support;
- local-only attachment policy;
- managed memory admission.

Score factors:

- capability-specific local quality;
- failures/malformed outputs;
- measured speed/load cost;
- quality-vs-latency preference;
- resident reuse;
- memory footprint.

Tie-breaking is stable by model identifier. Decisions contain requirements, stages, reasons, warnings, scores, and ordered fallbacks.

Documents always normalize before model execution. Multi-image comparisons deliberately use vision extraction → reasoning → validation rather than trusting one visual response. Scanned documents use page rendering → OCR → reasoning. Audio analysis uses transcription → reasoning. Long normalized text is handled with bounded map/reduce synthesis.

## Lifecycle and memory

`ModelResourceManager` is an actor and the only component allowed to load/unload model weights. It:

- shares one in-flight load task among concurrent requests;
- reserves estimated bytes before suspending for load;
- evicts idle residents before rejecting admission;
- tracks active request counts and last use;
- unloads after idle timeout or application termination;
- applies measured peak memory with headroom where available;
- derives its budget from both physical and current `vm_stat` availability;
- records actual fallback paths.

Workers bind to probed loopback ports. Readiness verifies the requested model identity rather than accepting an arbitrary HTTP 200. A process registry synchronously terminates children during application shutdown.

## Pipeline contracts and recovery

Intermediate values are `PipelineArtifact`s with kind, content, source provenance, confidence, and metadata. OCR has a basic repetition/completeness confidence gate. Structured JSON is normalized/validated only at the terminal stage, retried once, then falls back.

Every completed stage produces an `ExecutionCheckpoint`; artifacts survive a downstream failure. Final traces contain the requested route and actual execution path. Jobs are retained locally with a 50-job cap. Temporary page images are deleted after success or failure.

## Local-only and limits

- Remote attachment URLs are rejected in local-only mode.
- Files must exist, be readable, and be regular local files.
- Limits: images 50 MiB, code/text 8 MiB, audio 250 MiB, documents 512 MiB, PDF 250 pages.
- Worker hosts are explicit `127.0.0.1`.
- Normal inference runs with `HF_HUB_OFFLINE=1`.
- No cloud API key, endpoint, or fallback is implemented.

## V1 preservation

Manual is the default for fresh/existing users unless they persist Auto. V1 discovery, command construction, menu control, port 8081 endpoint, SSE parsing, commands, and conversation-history behavior remain. If an Auto/attachment request must reclaim a running V1 model, V2 stops it, performs centrally-managed work, unloads Auto workers, and restores the V1 server afterward.


## V3 extensions

V3 leaves the V2 module graph intact. `ModelProfiles.swift` adds evidence-backed deployable configurations; `ResourceManager.swift` now validates/resumes checkpoints and persists nullable stage telemetry; `DeterministicValidation.swift` provides abstaining claim validation; and `V3Orchestration.swift` defines a separate permissioned workflow plane. Inference transport remains direct loopback HTTP/SSE while typed workflows use MCP at the Prime boundary. See `V3/ADR-001-HYBRID-BOUNDARY.md`, `V3/PRIVACY-PERMISSIONS.md`, and `V3/TRACER-REPORT.md`.
