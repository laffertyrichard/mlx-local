# ADR-001: Hybrid Prime ↔ MLX Boundary

- **Status:** Accepted for V3
- **Date:** 2026-08-09
- **Decision:** Keep direct loopback OpenAI-compatible HTTP/SSE for inference and use typed MCP tools for permissioned workflows.

## Context

V2's V1 endpoint is trusted, local-only, streaming-capable, and externally compatible. V3 also needs discoverable workflow schemas, narrow permissions, provenance, cancellation, and restart isolation. Choosing a boundary by elegance would violate the evidence-first constraint, so three executable spikes were measured on the target M4 Pro/64 GB host.

## Evidence

`scripts/v3_boundary_bakeoff.py` executes one scoped artifact workflow plus live `/v1/models` access 30 times through each candidate. See `boundary-bakeoff.json`.

| Candidate | Median | p95 | Strength | Why it lost/won |
|---|---:|---:|---|---|
| HTTP | 16.94 ms | 43.40 ms | Familiar direct transport, V1 SSE | Lost: bespoke workflow discovery/auth duplicates tool schema and couples model and workflow APIs. |
| MCP | 16.53 ms | 40.08 ms | Typed discovery and structured tool results | Lost: wrapping all model traffic adds proxy/framing coupling and weakens direct V1/SSE compatibility. |
| Hybrid | 16.36 ms | 37.70 ms | MCP workflow contract + unchanged direct V1 inference | **Won:** preserves trusted inference while adding the narrower workflow plane; process failures were isolated. |

The differences are too small to rank transport performance; the Pareto decision retains latency, compatibility, permissions, streaming, coupling, and isolation separately. Both HTTP and MCP denied `/etc/hosts`. Killing MCP left workflow HTTP and V1 healthy. These are control-plane measurements, not generation benchmarks.

## Contract and ownership

- **Prime decides what work occurs.** It discovers/invokes versioned workflow IDs and supplies explicit grants.
- **MLX Menu decides how local inference occurs.** Capability routing, profile selection, model loading, fallback, and local artifacts stay in `LocalLLMCore`/`LocalInferenceBackends`.
- MCP workflow tools expose JSON Schemas and structured provenance; they do not expose shell or arbitrary filesystem primitives.
- Inference continues over fixed `127.0.0.1` endpoints. No cloud provider is configured.

## Consequences and rollback

The two planes have independent cancellation and health semantics, which is intentional isolation but requires correlation IDs. `scripts/v3_mcp_server.py` is a measured reference adapter, while the production permission model is `PermissionedWorkflowExecutor` in `V3Orchestration.swift`. Revert this ADR by disabling MCP workflow registration; V1/V2 inference remains unchanged. Do not replace V1 HTTP with MCP absent new measured evidence.
