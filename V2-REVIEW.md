# V2 Adversarial Review

Two independent read-only reviewers examined arbitrary text/images/PDFs/scans/audio, routing quality, memory, recovery, privacy, V1 preservation, and test coverage. The following issues were reproduced or confirmed and fixed before release.

| Finding | Resolution |
|---|---|
| Direct PDF routes could answer without receiving the PDF | All documents now pass native normalization before model execution; raw document input is never claimed by an adapter that cannot transport it |
| Code attachments were classified but not read | Bounded UTF-8 code contents are included in the backend prompt; unreadable files fail explicitly |
| Mixed inputs were discarded by an `else-if` classifier | Classification now accumulates requirements for every modality; audio and OCR fan out per file/page; mixed routes end in synthesis |
| Structured JSON validation poisoned OCR/transcription intermediates | JSON/schema requirements now apply only to the terminal stage; fenced JSON is normalized, retried once, then falls back |
| Model loads could race under actor reentrancy | Per-model shared load tasks and byte reservations serialize admission and prevent duplicate loads |
| Intermediate OCR/transcript work vanished after downstream failure | Every stage now emits and persists an `ExecutionCheckpoint` plus artifact files |
| Auto default/behavior disrupted V1 and dropped history | Manual is the persisted default, routed history is bounded and included, and a running V1 server is restored after Auto work |
| Idle/orphan workers and temp pages leaked | Idle unload is scheduled, application termination synchronously terminates child workers, temp pages are removed, and job retention is capped at 50 |
| Routing excluded models that fit after idle eviction | Resource snapshots expose reclaimable bytes; admission performs final eviction with load reservations |
| `localOnly` was unenforced and remote URLs could trigger network reads | Router rejects remote URLs and validates existence/readability/type-specific size/page limits |
| Worker ports/readiness could target another service | Ports are OS-probed and model identity is required in readiness responses |
| Images could be skipped/mislabeled; huge payloads could spike memory | Decode failures are fatal, images are locally normalized to PNG and resized to 4096 px, and input limits are explicit |
| Context was not derived or bounded | UI estimates text/code/document context, registry filters context capability, and long normalized artifacts use map/reduce synthesis |
| Multi-image direct response made incorrect arithmetic | Multi-image comparison now routes through vision extraction → reasoning → validation |
| Existing test files were disconnected from this toolchain | V1 checks and V2 adversarial cases were migrated into the framework-independent `RouterEvaluation` executable run by `scripts/test.sh` |

## Remaining adversarial weaknesses

- The free-port check is a probe rather than a kernel-held atomic reservation; a different process could win the small bind race between probe and worker spawn. Failure is explicit and falls back, but a future helper should pass a pre-bound socket.
- Timeout cancellation is cooperative. URLSession and worker polling respond to cancellation, and PDF/audio loops check it; a backend that ignores a cancelled HTTP request can continue computing until its worker is unloaded.
- Current memory pressure estimation uses `vm_stat`, cached size plus headroom, and measured peaks. It is safer than weight-size alone but is not continuous per-process Metal/KV telemetry.
- OCR confidence is a repetition/completeness heuristic, not calibrated probabilistic confidence.
- The 250-page and byte limits require users to split unusually large jobs. A future durable batch scheduler should page/chunk without one interactive request lifetime.
- The local benchmark set is small; multi-image arithmetic, noisy speech, diarization, and adversarial structured schemas need broader gold sets.
