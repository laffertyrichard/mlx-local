# MLX Menu V3 Evidence Index

V3 extends the known-good V2 local capability router; it is not a rewrite. Manual mode, the public V1 loopback endpoint/SSE behavior, deterministic capability routing, and local-only defaults remain intact.

## Reproducible evidence

- [`BASELINE.md`](BASELINE.md), [`baseline-v2.json`](baseline-v2.json) — pre-change V2 snapshot.
- [`ADR-001-HYBRID-BOUNDARY.md`](ADR-001-HYBRID-BOUNDARY.md), [`boundary-bakeoff.json`](boundary-bakeoff.json) — measured HTTP/MCP/hybrid spikes and selection.
- [`OPTIMIZATION-REPORT.md`](OPTIMIZATION-REPORT.md), [`profile-experiment-definition.json`](profile-experiment-definition.json), [`profile-experiment-results.json`](profile-experiment-results.json) — frozen splits and real local model runs.
- [`model-profiles.json`](model-profiles.json) — reversible CURRENT/RETIRED deployable profiles and promotion evidence.
- [`TRACER-REPORT.md`](TRACER-REPORT.md), [`construction-tracer-result.json`](construction-tracer-result.json) — real local Construction Plan Intelligence tracer with interruption/restart/resume.
- [`PRIVACY-PERMISSIONS.md`](PRIVACY-PERMISSIONS.md) — permission, audit, egress, and cloud-escalation contract.

## Gates

```bash
./scripts/test.sh                 # RouterEvaluation, not swift test
swift build -c debug
swift build -c release
python3 scripts/v3_verify_profile_results.py
python3 scripts/v3_boundary_bakeoff.py --iterations 30
python3 scripts/v3_run_hybrid_tracer.py
```

The expensive tracer is local-only and runs serially. Metrics unavailable from current backend APIs remain `null`/listed as unknown rather than estimated.
