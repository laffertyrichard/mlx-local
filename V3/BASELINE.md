# V2 Reproducible Baseline

Captured 2026-08-09T04:03:09.758019+00:00 at `7a8d3ad7a29ba2a7027bf821d3b8983fc3a50a6c` before V3 behavior changes.

- `./scripts/test.sh`: 31/31 checks passed.
- `swift build`: passed.
- `swift build -c release`: passed.
- Installed app and LaunchAgent: running; registry: 21 models.
- `GET /v1/models`: HTTP 200.
- V1 completion: exact `V3 BASELINE`, 10.306 s cold/uncached request, 24 total tokens.
- V1 SSE: first event 233 ms, total 247 ms, fragments `STREAM` + ` OK`, terminal `[DONE]`.
- Current process RSS observation: app 102219776 bytes; V1 worker 2522955776 bytes. RSS is not presented as Metal peak.
- Existing representative V2 multimodal measurements are retained in `BENCHMARKS.md` and copied into `baseline-v2.json`; V3 fresh runs append to the experiment registry rather than rewriting this baseline.

## Reproduce

```bash
./scripts/test.sh
swift build
swift build -c release
curl -sS http://127.0.0.1:8080/v1/models
```

Machine-readable evidence: [`baseline-v2.json`](baseline-v2.json).
