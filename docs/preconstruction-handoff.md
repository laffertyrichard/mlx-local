# Preconstruction takeoff handoff (2026-10-19)

Read first: `Preconstruction/README.md`, `Preconstruction/AGENTS.md`, `Preconstruction/docs/CONTRACTS.md`, `Preconstruction/docs/ROADMAP.md`, `Preconstruction/docs/ACCEPTANCE.md` (A01-A40). The original development brief is `Preconstruction/CLAUDE-DEVELOPMENT-PROMPT.md`.

## State

Branch `feat/package-installer`, on top of `3f6bf3d`:

| Commit | Content |
|---|---|
| `cf6b961` | `Preconstruction/` package imported unchanged (skills, fixtures, schema, template, Python checks) |
| `f7d0a01` | Swift core: domain records, deterministic takeoff, project store, scope preview, tests |
| `8c7fadd` | Phase 2 UI (`Sources/MLXMenu/PreconstructionView.swift`), traced-measurement drafts, measurement-bound checkpoints |

**Uncommitted user work, do not stage/reset/stash/edit:** `Sources/LocalLLMCore/ResourceManager.swift`, `Sources/MLXMenu/AutoRouterController.swift`, `Tests/LocalLLMCoreTests/ResourceBudgetTests.swift`.

Roadmap phases 0-2 are implemented. Phase 3 core is implemented against mock runtimes (session 3, uncommitted); no real model wired or evaluated. Phases 4-8 are not started.

## Code map

- `Sources/LocalLLMCore/PreconstructionDomain.swift`: Codable records mirroring `Preconstruction/schemas/revision.schema.json` (snake_case via `PreconJSON`). `@Nullable` writes unknowns as explicit `null` (the schema requires it). `AreaPlane` is the existing area-helper schema, including the `zones` that `geometry.py` requires.
- `PreconstructionTakeoff.swift`:
  - `Calibration.evaluate` needs both an X and a Y check. If they disagree it returns `.conflict` with a nil scale; it never averages.
  - `Takeoff.area`, `length` and `physicalCount` calculate quantities.
  - Topology: a deduction must be contained in its gross polygon. Overlap between polygons of the same sign is reported as `.unavailable`.
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

- `nice -n 10 swift test -j 4`: 45/45 pass (12 pre-existing, 27 preconstruction takeoff, 6 interpretation; the A10 page-frame test runs 4 rotations). Test names carry acceptance IDs (A01-A03, A05-A09, A12-A24, A39, A40).
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

## Next steps (in order)

1. Done: `build-package.sh` built `dist/MLX-Menu-3.1.1.5.pkg` (unsigned) and `verify-package.sh` passed with the template allowlist. The app extracted from the pkg, launched from cwd `/`, created a project identical to its bundled template. Not installed; installing needs admin rights.
2. Same-sign overlap needs a Boolean polygon engine; until then topology must stay `unavailable`.
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
- A corrupt `interpretation/<id>.json` makes every run throw `staleCheckpoint`; files are write-once, so delete it by hand to rerun that unit.
- `InterpretationUnit.status` is a summary (a budget gap shows `partial` even if candidates are held); check each candidate's `heldReason` and the unit's `coverage`.
- Unknown values stay nil and are never zero. Model output can only ever be a candidate, never accepted geometry. Approvals bind a snapshot digest.
