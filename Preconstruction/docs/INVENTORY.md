# Inventory: actual sources versus work to build

“Present” means files inspected and packaged; it does not mean local models execute that workflow or that app integration is complete.

| Capability | Existing implementation/evidence | Package and remaining work |
|---|---|---|
| Takeoff/intake | `takeoff-skill-codex/.agents/skills/plan-area-takeoff` and `takeoff-project-setup`; empty project template | Both skills and all scoped references included; integrate project lifecycle and UI in mlx-local |
| Deterministic area | `scripts/geometry.py` and regression tests | Included. Finite/simple polygon/ID/sign/area checks only; no inter-polygon topology, drawing fidelity, LF/EA or approval checks |
| CAD intake | `cad.py`, tests, author-machine wrapper | Included, wrapper made portable; ezdxf optional, DWG requires ODA and actual conversion evidence. Candidate CAD entities are not automatic scope quantities |
| Scope writing | Scope matching/design coordination/specification/revision references in takeoff; `buildertrend-proposal` skill | Included source-based workflow and plain-text adaptation. No standalone general scope-writing skill was found in searched locations. Claude must build manifest-bound scope generation and validation |
| Interior design | User skill `interior-design` with four references | Included guidance, no automatic design/model engine |
| Architectural planning | User skill `architectural-planning` with four references | Included spatial/coordination guidance; not structural certification |
| Building code research | User skill `building-code-review` with jurisdiction/evidence/source registers | Included dated research leads; adoption/edition/applicability must be freshly verified for a real project. Offline unverified findings stay unresolved |
| Cabinetry/built-ins | User skill `cabinetry-and-builtins` with five references | Included intent/fit/operation/support/QA guidance; no fabrication release or cut-list engine |
| Bid review | User skill `bid-package-review` | Included as optional document-review guidance. Historical customer example removed; no authenticated Buildertrend integration is supplied or required |
| Drawing overlays | Existing takeoff geometry-and-delivery, plan-comparison, CAD annotation guidance and helper | Included. No standalone overlay skill or reusable PDF overlay/export application was found in searched skill roots; source-linked net-mask PDF exporter remains to build |
| QA | Takeoff delivery checks, geometry/CAD tests, cabinet handoff/QA guidance | Included. Full topology, visual fidelity, cross-reference closure, workbook recalculation and approval orchestration remain to build |
| Architecture/model fidelity | `blender-test/.prime/agent/skills/blender-architecture` inspected | Project-bound skill contains customer decisions and live-model dependencies; deliberately excluded. Transferable review principles summarized in OPTIONAL-MODELING.md. No Blender/Prime dependency for MVP |
| mlx-local construction | Swift ConstructionTracer + deterministic claim validator + V3 checkpoints/workflow contract | Already present in target repo; not copied. Two-room synthetic tracer is narrow historical evidence, not plan-wide takeoff capability |

Eight packaged skills: plan-area-takeoff, takeoff-project-setup, interior-design, architectural-planning, building-code-review, cabinetry-and-builtins, bid-package-review, buildertrend-proposal. No claim that a discussed skill exists beyond these inspected files.

Search covered relevant immediate skills in `~/.codex/skills`, `~/.claude/skills`, `~/.agents/skills`, the takeoff project's `.agents/skills`, and the optional Blender project's `.prime/agent/skills`. This is a bounded local inventory, not a claim about every historical conversation or cloud-only skill. The cloud plan-area-takeoff listing was not used as a substitute for the actual local files.

## Sanitization and adaptation

- Never copied any customer project folder, source drawing, prior deliverable, raw activity history, model weight, runtime job or log.
- Replaced the two `recorded-workflow.md` customer-history examples with generic workflow summaries. Original hashes remain; original content stays at source.
- Changed author-machine workspace anchors into explicit configuration placeholders. Setup no longer defaults to the author's live takeoff workspace. Optional modeling paths are never implied authorization.
- Removed a named concurrent customer/model project from cabinet guidance.
- Proposal adaptation resolves its markdown/plain-text template conflict, defaults to scope without pricing, prevents unknown-to-zero owner-direct prices, and labels its CSI list as a legacy project convention. Reference exclusions/preliminaries are prompts requiring scope evidence, not default work or exclusions.
- No source file was edited. Changes exist only in this staged package. Public standards/source registries are retained as dated authoring evidence, not refreshed technical/legal recommendations.

No redistribution license was inferred. These are the user's requested internal project materials; review third-party rights before any broader publication. Third-party dependency code and paid standards are not bundled.
