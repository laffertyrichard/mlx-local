# Acceptance specification and evidence rules

Status: **application acceptance below is planned, not executed by this package**. `tests/test_contracts.py` checks only the synthetic package boundary and imported area helper. It is not a Swift UI, model, workbook or production takeoff test. `validation/REPORT.md` lists actual executed checks.

| ID | Given / action | Required observable result | Test level / gate |
|---|---|---|---|
| A01 | Empty project, no sources | Standard registers/checkpoint exist, awaiting-source state, no invented quantities | Domain + filesystem / intake |
| A02 | Same filename, changed bytes | Retain both immutable originals, new hash/revision, source links resolve | Filesystem / intake |
| A03 | Traversal, symlink escape, non-file URL | Deny before read/write; audit narrow failure; no external changes | Permission / all phases |
| A04 | Source excerpt with printed sheet A-2 on actual page 3 | Store sheet and actual file index separately; missing indexed references remain explicit | Intake/visual |
| A05 | Synthetic room at 18 points/ft, 12 × 10 ft, 2 × 3 ft fixed deduction | Gross 120, deduction 6, installed 114 SF from same vertices; separate waste/order fields | Deterministic / quantity |
| A06 | Reversed polygon orientation, large translated coordinates | Same magnitude area, valid stable IDs/signs | Deterministic |
| A07 | Bow-tie, repeated/degenerate vertex, NaN, invalid scale/sign/duplicate ID | Reject before totals; never repair by hidden tolerance | Deterministic |
| A08 | Overlapping zones, overlapping deductions, protruding deduction, valid addback | Detect invalid occupancy/containment; union deductions only under an explicit ownership rule; valid addback restores deducted region | Topology / release |
| A09 | X dimension gives 18, Y gives 20 points/ft | Calibration conflict, no averaged scale or released quantity based on hidden fit | Domain/UI / basis |
| A10 | Cropped/rotated/resized page | Forward/inverse transform round-trips known landmarks; mark bounds checked in its own frame; original untouched | Preprocess/visual |
| A11 | Same page, differently scaled detail | Independent plane/calibration; no cross-detail scale reuse | Domain |
| A12 | LF route 12 + 10 ft open | 22 LF, no automatic closing segment; dimensional area uses proper face | Deterministic |
| A13 | Two physical fixtures, one repeated in another view | 2 EA, not 3 appearances; stable physical vs operation IDs | Deterministic |
| A14 | Existing retained 40 SF and proposed 114 SF | New total 114, retained 40 as reference; removals and installation separate operations | Domain/scope |
| A15 | Missing tile height and depicted untraced base run | Tile quantity null with question; untraced base run in unfinished register; neither zero nor silently excluded | Domain/scope |
| A16 | Two competing current source dimensions/materials | Preserve both; hold affected claim; recorded authority/decision only resolves within its scope | Revision/UI |
| A17 | Model guesses a missing room/material/dimension | Candidate rejected/held, exact source quote and evidence location required; no authoritative geometry write | Fake runtime + held-out local |
| A18 | OCR repetition, unreadable small dimension, page failure | Affected page/crop incomplete, coverage visible; bounded retry then local pause, no empty-as-zero | Runtime |
| A19 | Single-image OCR model and many pages | Sequential page/crop invocations, no multi-image batch; candidate IDs survive merge | Routing/runtime |
| A20 | Long plan/spec set exceeds budget | Bounded relevant chunks, explicit unresolved coverage, output budget reserved; no silent truncation | Routing/runtime |
| A21 | Insufficient memory while pricing workload runs | Defer/pause; no independent server starts or eviction of unrelated work; record reason and resume point | Resource/runtime |
| A22 | No compatible local model or malformed JSON after bounded retry | Explicit unavailable/failed stage with saved units; no cloud/network fallback or invented result | Routing/runtime |
| A23 | Cancel after page 1 or during draft | Resume completed units without rerunning valid extraction; transient files cleaned; owned weights released | Runtime/restart |
| A24 | Changed bytes/calibration/profile/pipeline/schema or corrupt checkpoint | Mark dependent units stale, reject reuse, invalidate affected approval; do not silently rerun everything | Persistence |
| A25 | Model scope says “120 SF” or invents removal, SKU, standard exclusion | Claim-to-quantity/source validator fails; correct 114 SF selected basis, material issues disclosed | Scope gate |
| A26 | Client/internal drafts with supplied vendor cost | Client contains no vendor cost; scope only unless pricing explicitly requested; no inferred markup | Export |
| A27 | Buildertrend line item >4000 chars, markdown/unicode or unitless quantity | Reject/split semantically preserving source IDs; plain text and explicit units | Export |
| A28 | Source callout without disposition or quantity without evidence | Bidirectional closure fails; unresolved work visible; cannot declare complete | QA/release |
| A29 | Overlay export of room and hole | Hole stays unfilled; mark IDs/style/quantity/unit match legend; no gross tint under deductions; net render mask matches geometry | Artifact + independent visual |
| A30 | Workbook source input changed or table sorted | Formulas and recalculated cached values update, IDs/categories stay attached, paired overlay stale until regenerated | Artifact/export |
| A31 | Same LF route also drives wall SF, alternate basis or informational total | Units/relationship explicit; totals never add both basis and derivative as same quantity | Domain/export |
| A32 | Revision changes material only, unknown→known or excerpt omits prior item | Nonnumeric change retained; not automatic addition/deletion; unchanged rows retain identity | Revision |
| A33 | Field/user answer resolves one issue | Source/date/decision scope preserved; all dependent registers/quantities/scope/overlays update together; unrelated issues stay open | Revision |
| A34 | Owner visual approval only | No automatic fabrication, field, engineering, procurement or code signoff | Approval |
| A35 | Code review lacks parcel authority, enactment/edition/amendment/date or exact section | Requirement remains unverified/conditional; no guaranteed compliance wording; dated AZ leads not treated as law | Code evidence |
| A36 | CAD unitless drawing, block insertion, xref gap, unsupported plane or dimension override | Explicit basis/dependency review; candidate geometry only, no automatic measured takeoff | Optional CAD |
| A37 | ODA detected but conversion not tested | DWG support unavailable/unverified until actual converter/version/hash/log/render evidence | Optional CAD |
| A38 | App trace retention expires / disk full during revision write | Durable project data survives trace cleanup; atomic old revision intact; explicit failure, no false release | Persistence |
| A39 | Scope export/issue action without human snapshot approval | Draft may be saved; external sending/import/order/submission denied pending distinct authorization | Approval |
| A40 | Existing V1/manual, Auto route and resource tests | Prior behavior preserved; existing failures distinguished from regressions; dirty user work intact | Regression |

## Required release evidence

Record each check as passed, failed, skipped or unavailable with its input/output hashes, validator/version, evidence artifact and narrow limits. Arithmetic, topology, visual source correspondence and scope completeness are four separate results. Mark workbook recalculation and actual rendered-output review separately. A proposed test or helper unit pass cannot stand in for source interpretation. Human approval must identify the revision digest and allowed use. Critical failed/unavailable required checks block the dependent release; preserve useful completed work.
