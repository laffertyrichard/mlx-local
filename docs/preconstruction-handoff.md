# Preconstruction takeoff handoff (2026-10-19)

Read first: `Preconstruction/README.md`, `Preconstruction/AGENTS.md`, `Preconstruction/docs/CONTRACTS.md`, `Preconstruction/docs/ROADMAP.md`, `Preconstruction/docs/ACCEPTANCE.md` (A01-A40). The original development brief is `Preconstruction/CLAUDE-DEVELOPMENT-PROMPT.md`.

## State

Branch `feat/package-installer`, on top of `3f6bf3d`:

| Commit | Content |
|---|---|
| `cf6b961` | `Preconstruction/` package imported unchanged (skills, fixtures, schema, template, Python checks) |
| `f7d0a01` | Swift core: domain records, deterministic takeoff, project store, scope preview, tests |
| `8c7fadd` | Phase 2 UI (`Sources/MLXMenu/PreconstructionView.swift`), traced-measurement drafts, measurement-bound checkpoints |

The live memory-budget work (`ResourceManager.swift`, `AutoRouterController.swift`, `ResourceBudgetTests.swift`) is on its own branch, `fix/memory-accounting`, and is not part of this branch.

Roadmap phases 0-2 are implemented. Phase 3 core is implemented against mock runtimes only (session 3; review fixes in session 4); no real model is wired or evaluated. Phases 4-8 are not started.

## Code map

- `Sources/LocalLLMCore/PreconstructionDomain.swift`: Codable records mirroring `Preconstruction/schemas/revision.schema.json` (snake_case via `PreconJSON`). `@Nullable` writes unknowns as explicit `null` (the schema requires it). `AreaPlane` is the existing area-helper schema, including the `zones` that `geometry.py` requires.
- `PreconstructionTakeoff.swift`:
  - `Calibration.evaluate` needs both an X and a Y check. If they disagree it returns `.conflict` with a nil scale; it never averages.
  - `Takeoff.area`, `length` and `physicalCount` calculate quantities.
  - Topology: a deduction must be contained in its gross polygon. Same-sign polygons that cross, nest or repeat fail, except an add-back (a positive polygon inside a deduction of its zone). Overlapping deductions fail (no ownership rule). Pairs that only touch (shared walls) are `.unavailable`. `.passed` only when every pair is decided.
  - `AreaPlane.revisionRecords` is the adapter from a plane to revision records.
  - `releasedTotal` / `provisionalTotal` / `releaseBlockers` handle totals and release gating.
- `PreconstructionMeasurements.swift`:
  - `TakeoffMeasurements` is the draft the UI edits.
  - It produces calibration, quantities and checks. Any scaled value is nil unless calibration is candidate/reviewed.
- `PreconstructionProject.swift` (`PreconProjectStore`):
  - Projects are created from the template into a named child of the data root.
  - Imports are hash-addressed (`sources/<sha256>/<name>`) and stored read-only (0444).
  - Symlinks, non-file URLs and paths outside the root are refused.
  - `writeNew` writes atomically and never overwrites.
  - Checkpoints bind the revision bytes, source hashes and measurement files. `resume` rejects stale or corrupt checkpoints.
  - `ScopePreview` renders a labelled template, ASCII only, with no pricing.
- `Sources/MLXMenu/PreconstructionView.swift`: `TakeoffController` plus the views.
  - Data root comes from env `PRECONSTRUCTION_WORKSPACE`, otherwise from the UserDefaults key `preconstructionWorkspace`.
  - Template lookup: `Bundle.main.resourceURL/preconstruction-template`, then `<cwd>/Preconstruction/templates/project`.
  - Each edit starts a new unsaved revision `Rn` and marks earlier approvals stale.
  - Approve sets the calibration to reviewed first, then binds `reviewed_geometry` to the snapshot digest.
  - One draft per source page (page picker). Save writes `measurements/Rn-<sourceId>-measurements.json` and `Rn-<sourceId>-plane.json` (helper schema) for every traced page, then `revisions/Rn.json` and a checkpoint.
  - Taps and overlays go through `PageFrame` (`PreconstructionPageFrame.swift`), so rotated pages and offset media boxes map to the unrotated top-left frame.
  - A stale newest checkpoint shows a recovery view: "Open Last Valid Checkpoint" or "Start New Revision".
- `MLXMenuApp.swift`: two additions only, the `Window("Preconstruction Takeoff", id: "takeoff")` scene and the "Open Takeoff" button in `MenuPanel`.

## Evidence

- `nice -n 10 swift test -j 4` on this branch: see Session 4 for the current count. The earlier "45/45" was the dirty tree: 36 committed + 6 interpretation + 3 resource-budget tests (the budget tests now live on `fix/memory-accounting`), not "12 + 27 + 6". Test names carry acceptance IDs (A01-A03, A05-A09, A12-A24, A39, A40).
- Package checks from `Preconstruction/`, all passing:
  - `python3 -B tests/test_contracts.py`: 10
  - `python3 -B skills/plan-area-takeoff/scripts/test_geometry.py`: 10
  - `python3 -B tools/verify_package.py`: passed
- Run once, outside the test suite:
  - Swift-encoded revision validated against `revision.schema.json` with Anaconda jsonschema.
  - Swift-written plane run through `geometry.py`: net 114.0.
- Not re-run: `test_cad.py`, `tests/test_optional_checks.py` (they need `/opt/homebrew/anaconda3/bin/python`).
- The UI was smoke-tested in session 2 (see below). Saved revisions from that run, with 2 sources and per-page IDs, validate against `revision.schema.json` (Anaconda jsonschema).

## Session 2 (2026-10-19, uncommitted)

- **Smoke test done** on the debug build with `PRECONSTRUCTION_WORKSPACE` set to a scratch root. Steps: create project, import, Cal X 216 pt = 12 ft, Cal Y 180 pt = 10 ft, trace the room and the island (114 SF), approve, save, then reopen with approval intact. `geometry.py` on the saved plane gave net 114.0. After an R2 label edit and save, the R2 plane file was edited; reopen was refused and listed the changed file.
  - The unbundled debug binary runs with activation policy "prohibited", so it never becomes the active app. Synthetic keystrokes can't reach its open panel, so the user did the PDF imports by hand. Clicks were driven by a scratch AX/CGEvent helper; that helper is not in the repo.
- **Bugs fixed:** in the empty state the project bar floated mid-window. Tool captions wrapped into a tall toolbar row, shifting the canvas mid-trace. `nextID` counted `G01` when numbering deductions (gave `D02`).
- **Limitations fixed:**
  - Page picker. One draft per source page, and measurement and plane files are `Rn-<sourceId>-…`. Quantity and check IDs end in the source ID. One approval covers every traced page.
  - Rotation and media-box origin. `PageFrame` in `PreconstructionPageFrame.swift`, with a render round-trip test at 0, 90, 180 and 270 degrees on an offset media box.
  - Template bundled at `Resources/preconstruction-template` via `ditto --noextattr`, and listed in the `verify-package.sh` allowlist. Checked on a throwaway signed bundle only; `build-package.sh` has not been run.
  - Stale-checkpoint recovery. It lists the reasons and offers "Open Last Valid Checkpoint" or "Start New Revision". Neither changes any file.
- Tests: 39/39 (`nice -n 10 swift test -j 4`). Package checks still pass.

## Session 3 (2026-10-19, uncommitted): Phase 3 core

- `Sources/LocalLLMCore/PreconstructionInterpretation.swift`, `InterpretationPipeline`:
  - Per source page: native PDF text (PDFKit) first; empty page goes to OCR, one PNG per call, removed after the call. `VisionFocus` crops (stored frame, rotation-aware via `PageFrame`) go to a vision call.
  - Model seam is `PreconInterpreter = (InterpretationRequest) async throws -> String` (raw JSON). Decoded with `JSONDecoder`; malformed output gets one retry (`isRetry`), then the unit is `failed`.
  - Output is `InterpretationCandidate` only. A candidate is held (`heldReason`) when it has no quote, its quote is not verbatim in the page text, or confidence < 0.6. Vision quotes verify against native page text, so on scans every vision candidate is held. Nothing in this file touches calibrations, measurements, quantities or revisions.
  - Text over `InterpretationBudget.maxInputChars` is chunked by line; chunks past `maxChunks` are listed in `coverage` and the unit is `partial`.
  - `gate` runs before every model call; a reason defers the unit and stops the run.
  - Unit ID = digest of pipeline version, profile, confidence threshold, budget, source sha256, page and crop. `complete`/`held`/`partial` units are saved write-once to `interpretation/<id>.json` (`PreconProjectStore.saveInterpretation`) and reused on rerun; any input change gives a new ID. `incomplete`/`failed`/`deferred` are not saved and rerun.
- `PreconProjectStore.contained` is now internal (was private) so the pipeline reuses the root check.
- Tests: 6 new in suite "Preconstruction assisted interpretation" (A17, A18/A19, A20, A21/A23, A22, vision crop), all on a scripted mock. `nice -n 10 swift test -j 4`: 45/45.
- Interpretation units are not bound into `ProjectCheckpoint`; their own digest IDs carry staleness.

## Session 4 (2026-10-23): corrective pass on the three-review findings

Branch `fix/interpretation-integrity` (baseline commit `c1aa1aa` = session 3 work committed unchanged). Each finding has a regression test named with its ID.

| ID | Finding | Disposition |
|---|---|---|
| F01 | Symlinked child dirs (`measurements/`, `revisions/`, `checkpoints/`, `interpretation/`, `sources/<hash>/`) let writes escape the root: `resolvingSymlinksInPath` leaves a missing leaf unresolved | Fixed: `contained` resolves the deepest existing ancestor and refuses dangling links; every write goes through it |
| F02 | A saved interpretation unit was returned before the PDF was re-hashed | Fixed: current bytes are hashed before any saved unit is used |
| F03 | Prompt text not in unit identity | Fixed: instructions are pipeline properties digested into the ID; version bumped to `precon-interpret-2` for code-side rule changes |
| F04 | A failed save part-way left files that write-once refused on retry | Fixed: `PreconProjectStore.saveRevision(_:measurements:in:)` writes the checkpoint last; identical bytes are reused on retry; changed work moves to a fresh revision ID (view) |
| F05 | Corrupt files reported as stale | Fixed: `PreconProjectError.corrupt`; the view still shows the recovery choices |
| F06 | `VisionFocus` short/NaN/inf rects crashed the process | Fixed: shape, finiteness, size, page bounds and known source checked before any call (`TakeoffError.invalidGeometry`) |
| F07 | m/in/mm plane areas labelled SF unconverted | Fixed: squared length factor; unknown units still throw |
| F08 | Same fixture on two pages counted twice | Fixed: `TakeoffMeasurements.quantities(across:)` combines counts per trade by physical item ID only |
| F09 | Candidate text unchecked against its quote; substring quotes | Fixed: quote tokens must appear consecutively in the source, and every text token must be in the quote |
| F10 | OCR candidates "verified" against the same OCR output | Fixed: with no native text layer every candidate is held, reason names the needed source-image check |
| F11 | Crop test checked only aspect ratio | Not a code defect (baseline passes); landmark test added for 4 rotations on an offset media box |
| F12 | A08 overlap/add-back incomplete | Fixed for crossing, nested, repeated and add-back cases; touching pairs stay `unavailable` (not accepted) |
| F13 | A11 differently scaled details on one page | **Blocked, not accepted.** One calibration per page draft; a second detail scale on the same page is unsupported and must be traced on its own page/source |
| F14 | 1e-9 calibration tolerance | Fixed: agreement judged by click uncertainty (1 PDF pt per endpoint, scale x 2u / L per witness) plus a separate 1e-9 float term; the longest witness's scale is used, never an average |
| F16 | Handoff test counts | Reconciled (see Evidence) |

Tests on this branch (`swift test list`, parameterised tests count once): 68 = model cache 9, takeoff 13, project 8, measurements 5, page frame 1 (4 rotations), interpretation 6, corrective regressions 13, adversarial 13. 36 of these predate session 3.

Regression evidence: the tests that compile against `c1aa1aa` fail there (F01 import, F02, F06 crash, F07, F09, F12); OpenCode's adversarial suite (`PreconstructionAdversarialTests.swift`, written against the baseline) independently failed for F01, F02, F04, F05, F06, F07, F08, F09, F10.

Next real-model gate (not started, needs explicit authorization and a quiet window): a `PreconInterpreter` adapter over `ModelRuntime`, then a small held-out synthetic evaluation. Phase 3 accuracy is unevaluated.

## Next steps (in order)

1. Done: `build-package.sh` built `dist/MLX-Menu-3.1.1.5.pkg` (unsigned) and `verify-package.sh` passed with the template allowlist. The app extracted from the pkg, launched from cwd `/`, created a project identical to its bundled template. Not installed; installing needs admin rights.
2. Touching same-sign polygons (rooms sharing a wall) need a Boolean polygon engine to decide; until then that pair stays `unavailable`.
3. Phase 3 follow-ups (core done, see Session 3):
   - Real interpreter adapter: a `PreconInterpreter` closure over `ModelRuntime` (text model for candidates, single-image OCR/vision model). Apple Vision `VNRecognizeTextRequest` is a candidate for the OCR stage. Not written.
   - Wire `gate` to `ResourceManager`'s public budget API (read only; that file is dirty user work).
   - UI: "Read Page" in the takeoff window listing candidates with quote/held reason. Not written.
   - Small held-out local evaluation: needs explicit user authorization and a quiet window, because the Mac runs a trade-pricing workload.

## Rules and gotchas

- Don't add or edit files under `Preconstruction/`. `verify_package.py` checksums every file there.
- Run the package's Python with `python3 -B`, not `-I`. `-I` ignores `PYTHONDONTWRITEBYTECODE` and drops the script directory from `sys.path`, so imports fail and `__pycache__` breaks verification.
- Run tests with `nice -n 10` on this shared Mac. Never run installs, model loads, benchmarks, the V3 tracer, cloud calls or pushes without asking.
- Commit only when asked. Commit messages: imperative, about "why", ending with the Co-Authored-By trailer.
- A corrupt `interpretation/<id>.json` or checkpoint throws `PreconProjectError.corrupt` (not `staleCheckpoint`); files are write-once, so delete it by hand to rerun that unit.
- `InterpretationUnit.status` is a summary (a budget gap shows `partial` even if candidates are held); check each candidate's `heldReason` and the unit's `coverage`.
- Unknown values stay nil and are never zero. Model output can only ever be a candidate, never accepted geometry. Approvals bind a snapshot digest.
