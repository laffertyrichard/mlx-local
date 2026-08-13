# V3 Permission, Privacy, and Egress Contract

## Production workflow surface

`Sources/LocalLLMCore/V3Orchestration.swift` defines a versioned `WorkflowDescriptor` with input/output schema, required capabilities, readable/writable roots, network grants, executable allowlist, confirmation, timeout, cooperative cancellation, retry/idempotency, checkpoint support, artifact kinds, and resource estimate. `PermissionedWorkflowExecutor` and `WorkflowCapabilityBroker`:

1. resolve symlinks and checks path-component boundaries against declared roots;
2. deny non-file URLs and out-of-scope reads/writes before execution;
3. broker actual regular-file reads with 64 MiB bounds and audit the operations actually performed;
4. provide no brokered shell, generic filesystem, or network operation;
5. apply cooperative timeout/cancellation and cache only explicitly idempotent invocation IDs; and
6. append JSONL audit records for success, denial, and failure.

The built-in construction inventory workflow can only hash explicitly requested files beneath one configured root. It has no network or process permission. RouterEvaluation proves an allowed invocation, audit persistence, and denial of `/etc/hosts`. The HTTP and MCP spikes independently prove the same denial behavior.

## Network and trust boundaries

All shipped model workers bind to `127.0.0.1`. MCP uses child-process stdio. The HTTP spike requires a bearer token and loopback bind; it is not the selected workflow plane. Raw content and artifacts remain local. Audit records include paths, grant shape, outcome, and detail; they must be protected with the same user permissions as Application Support.

## Cloud escalation

V3 has only a design record (`CloudEscalationProposal`), **not a provider client or execution path**. Any future escalation must state why local is insufficient, provider/model, exact data leaving the machine, whether raw attachments are required, redaction, benefit, token/cost estimates, denied behavior, and obtain explicit per-invocation authorization. Denial must terminate or continue locally—it must never silently fall back. Credentials belong in Keychain and provider/network grants must be revocable and audited before implementation.

## Revocation and rollback

Unregister a workflow or remove its permission roots to revoke it. Profile rollback is independent. Disabling the MCP adapter leaves Manual/V1 and Auto routing intact. No workflow may mutate routing metadata or promote a profile without a separate held-out evidence record and explicit registry operation.


### Trust and persistence limits

In-process handlers are trusted code, not an OS sandbox: Swift ambient APIs cannot be made unavailable by a type contract. Registration is therefore named `registerTrusted`, and handlers must use the broker. Any third-party/untrusted workflow must run in a killable OS-sandboxed child process before being accepted as a security boundary. Cooperative timeout is not a hard kill for cancellation-ignoring code.

Job state contains plaintext prompts, artifact content, and source paths under user-only Application Support (directories `0700`, structured files `0600`). This enables restart resume but is a local disclosure surface. V3 retains at most 50 jobs, seven days, and 1 GiB; stale/corrupt/non-resumable jobs clean temporary rendered inputs. The UI exposes Resume and Discard for incomplete jobs. Disk encryption remains the host/user responsibility.
