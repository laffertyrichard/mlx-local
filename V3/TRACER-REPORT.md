# Construction Plan Intelligence Tracer

## Acceptance case

The tracer uses two previously unseen synthetic plan images: `LOBBY E` (14 × 6.5 = 91 sq ft) and `OFFICE F` (10.25 × 9 = 92.25 sq ft). It must cover both images, preserve uncertainty fields, invent no labels/values, retain source/profile provenance, survive interruption, reject stale inputs, avoid recomputing valid extraction, and use no cloud fallback.

## Winning-boundary run

`python3 scripts/v3_run_hybrid_tracer.py`:

1. starts the MCP stdio adapter;
2. invokes the scoped construction inventory tool for both images and obtains hashes/provenance;
3. confirms live local model control through the fixed V1 loopback endpoint;
4. runs `ConstructionTracer` with CURRENT profile `qwen3-vl-30b-construction-json@1`;
5. persists a source/profile/pipeline-bound checkpoint after real VLM extraction;
6. deliberately cancels and shuts down the first resource manager;
7. decodes the checkpoint from disk into a new manager;
8. reuses extraction and performs deterministic schema/arithmetic validation; and
9. terminates all temporary processes.

## Result

`construction-tracer-result.json` records:

- accepted output: exact labels and areas 91 / 92.25;
- both MCP artifact hashes and local model count (21);
- interruption observed and checkpoint completed stage count 1;
- resumed extraction telemetry `reused=true`;
- resume/validation time 0.315 ms;
- no model loaded after restart, proving expensive extraction did not rerun;
- profile and source digests, validator ID, source URLs, and uncertainty fields;
- no cloud fallback.

Checkpoint validity binds SHA-256 source content hashes/lengths/paths, request/schema, semantic stages, profile digests, pipeline/preprocessing versions, and relevant configuration. Changed input/configuration throws `staleCheckpoint`; legacy context-free and inconsistent checkpoints are rejected. Corrupted UI checkpoint files now fail explicitly rather than silently rerunning.

## Limitations

This narrow tracer proves the architecture, not broad construction accuracy. Current backend calls do not expose truthful TTFT or exact Metal/KV memory; those remain unknown. Wider held-out plans, cancellation during backend generation, and MCP progress notifications should be added before claiming production-scale accuracy.
