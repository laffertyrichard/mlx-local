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
  - Topology: a deduction must be strictly inside its gross polygon (touching the boundary is `.unavailable`). Same-sign polygons that cross, nest or repeat fail, except an add-back (a positive polygon inside a deduction of its zone). Overlapping deductions fail (no ownership rule). Pairs that only touch (shared walls) are `.unavailable`. `.passed` only when every pair is decided.
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

Branch `fix/interpretation-integrity` (baseline commit `c1aa1aa` = session 3 work committed unchanged). Not every finding is closed: A11 (F13) is blocked, touching polygons stay `unavailable`, and the running-app save/retry walkthrough is still open. See "Status by category" below the table.

| ID | Finding | Disposition |
|---|---|---|
| F01 | Symlinked child dirs (`measurements/`, `revisions/`, `checkpoints/`, `interpretation/`, `sources/<hash>/`) let writes escape the root: `resolvingSymlinksInPath` leaves a missing leaf unresolved | Fixed: `contained` resolves the deepest existing ancestor and refuses dangling links; every write goes through it |
| F02 | A saved interpretation unit was returned before the PDF was re-hashed | Fixed: current bytes are hashed before any saved unit is used |
| F03 | Prompt text not in unit identity | Fixed: instructions are pipeline properties digested into the ID; version bumped (now `precon-interpret-4`) for code-side rule changes |
| F04 | A failed save part-way left files that write-once refused on retry | Fixed: `PreconProjectStore.saveRevision(_:measurements:in:)` writes the checkpoint last; identical bytes are reused on retry; changed work is detected by a tested core bundle-compatibility helper, including removed measurement files; controller wiring and the native walkthrough remain untested |
| F05 | Corrupt files reported as stale | Fixed: `PreconProjectError.corrupt`; the view still shows the recovery choices |
| F06 | `VisionFocus` short/NaN/inf rects crashed the process | Fixed: shape, finiteness, size, page bounds and known source checked before any call (`TakeoffError.invalidGeometry`) |
| F07 | m/in/mm plane areas labelled SF unconverted | Fixed: squared length factor; unknown units still throw |
| F08 | Same fixture on two pages counted twice | Fixed: `TakeoffMeasurements.quantities(across:)` combines counts per trade by physical item ID only |
| F09 | Candidate text unchecked against its quote; substring quotes | Fixed (final rule after N02/R2-I02/R3-I01): the quote must appear literally in the source, whitespace-normalised, on word boundaries that never split a number, and the candidate's words must appear in the quote in order |
| F10 | OCR candidates "verified" against the same OCR output | Fixed: with no native text layer every candidate is held, reason names the needed source-image check |
| F11 | Crop test checked only aspect ratio | Not a code defect (baseline passes); landmark test added for 4 rotations on an offset media box |
| F12 | A08 overlap/add-back incomplete | Fixed for crossing, nested, repeated and add-back cases; touching pairs stay `unavailable` (not accepted) |
| F13 | A11 differently scaled details on one page | **Blocked, not accepted.** One calibration per page. Before the closeout guard, re-clicking both witnesses on a 1/2-scale detail silently rescaled already-traced plan area (120 to 30 SF, still `candidate`). Now `TakeoffMeasurements.calibrationChecks(adding:)` refuses a witness that disagrees with an established scale once areas or routes are traced, and the calibration panel states the one-scale rule. This is a guard on a known operation, not detection of mixed-scale drawings: a detail traced at the page scale without recalibrating is still measured at the page scale |
| F14 | 1e-9 calibration tolerance | Fixed: agreement judged by click uncertainty (1 PDF pt per endpoint, scale x 2u / L per witness) plus a separate 1e-9 float term; the longest witness's scale is used, never an average |
| F16 | Handoff test counts | Reconciled (see Evidence) |
| N01 | (Codex review of the fixes) duplicate or nested add-backs skipped the overlap check | Fixed: only an add-back's overlap with its surrounding gross polygon is exempt |
| N02 | (Codex) token matching dropped punctuation, so `1.2 in` matched `1/2 in`; candidate words were unordered | Fixed: whitespace-normalised literal match on word boundaries; candidate words must appear in the quote in order |
| N03 | (Codex) a deduction touching a concave boundary was promoted to `.passed` | Fixed: deductions and add-backs pass containment only when strictly inside; touching stays `unavailable` |
| N04 | (Codex, P3) corrupt checkpoint shown as "stale" in the recovery panel | Fixed: panel says corrupt |
| R2-I01 | (Codex round 2) quote rules changed without a pipeline version bump, so units saved under the old rules would be reused | Fixed: version bumped (`precon-interpret-3`, then `-4`) |
| R2-I02 | (Codex round 2) a quote could start or end inside a number (`2 in` from `1/2 in`) | Fixed: `/ . ,` between digits is not a word boundary |
| R3-I01 | (Codex round 3) a leading decimal could still be split (`5 in` from `.5 in`) | Fixed: a `/ . ,` directly before a quote's leading digit always splits; version `precon-interpret-4` |

### Status by category

- **Fixed defects, with a test that failed before the fix:** F01, F02, F04, F05, F06 (crashed the test process), F07, F08, F09, F10, F12. The tests that compile against `c1aa1aa` fail there (F01 import, F02, F06, F07, F09, F12). OpenCode's adversarial suite, written against the baseline, failed independently for F01, F02, F04, F05, F06, F07, F08, F09 and F10. Codex follow-ups N01-N03, R2-I01, R2-I02 and R3-I01 each had a failing test before their fix.
- **Fixed without equivalent red-first evidence:** F03 (OpenCode's baseline test documented the gap rather than failing) and F14 (its test uses the new `endpointUncertainty:` parameter, which doesn't exist on the baseline). N04 is a UI wording change with no test.
- **Not a defect:** F11. The crop code was already correct; only test coverage changed.
- **Accepted scope:** one calibration per page; candidate output only (never quantities); topology `.passed` only when every pair is decided.
- **Deferred capabilities (not accepted):** A11 independent detail planes; deciding touching same-sign polygons (needs a Boolean polygon engine); a real interpreter.
- **Untested:** the save/retry and recovery paths clicked through in the running app (see the checklist in Next steps); native UI rendering in general; any real model, OCR or vision accuracy. Phase 3 is mock-only and its accuracy is unevaluated.

Tests on this branch (`swift test list`, parameterised tests count once): see the closeout section for the current count. At `9c9a6b9`: 71 = model cache 9, takeoff 13, project 8, measurements 5, page frame 1 (4 rotations), interpretation 6, corrective regressions 16, adversarial 13. 36 of these predate session 3.

Next real-model gate (not started, needs explicit authorization and a quiet window): a `PreconInterpreter` adapter over `ModelRuntime`, then a small held-out synthetic evaluation. Phase 3 accuracy is unevaluated.

## Session 5 (2026-10-23): acceptance closeout

- A11 guard: recalibrating a page that already has traced areas or routes is refused when the new witness disagrees with the established scale (`TakeoffError.unsupportedMixedScale`). Counts-only pages, untraced pages and pages whose calibration is already in conflict can still be recalibrated. A11 stays blocked and unaccepted.
- Save seam: `PreconProjectStore.beforeWrite`, wired from `PRECONSTRUCTION_TEST_FAIL_SAVE` in debug builds only. Core tests use it to fail each write stage; the running-app walkthrough that uses it is still open (Next steps, item 0).
- Original closeout: 85 tests; three production-bundle tests and two C1-01 regressions bring this branch to 90. R-b core helper tests cover removed/renamed file sets and unchanged partial retries; controller wiring and the native walkthrough remain untested.
- Memory (PR #2) qualifications are on `fix/memory-accounting`: reservations use registry estimates rather than measured peaks; active-model KV growth is not attributed per model; no real-model memory evaluation has been done.

## Session 6 (2026-10-26): merges and runtime-backed Read Page

Roles: Claude coordinated through Orca Run `run_397dcf33146d`, Prime built, Codex reviewed. Prime is not a registered Orca agent (`worker-start` times out at `agent_readiness`), so Prime's Dispatches were sent with `dispatch --inject` and Orca records them as unsupervised. Codex ran as supervised `worker-start --agent codex` sessions. Prime started two Codex helpers on its own (`ctx_7869d339ad9b`, read-only log search; `ctx_f7b122d1a1ba`, drafting C3). The second was stopped, and its one untracked test file was deleted. Prime then wrote C3 itself. Codex found no helper-authored code in git, but git can't prove line authorship.

All evidence is in `/Users/mccully/projects/mlx-local-evidence/2026-10-26/` (outside the repo). Each `*.log` ends with `exit=<code>`, and `SUMMARY.md`, `c1-01-fix.md`, `slice-core.md`, `slice-ui-eval.md` and `c4fix.md` list every command.

**Identities**

| What | SHA |
|---|---|
| Base of both PRs | `67565a7` (`feat/package-installer`) |
| PR #2 `fix/memory-accounting` head / merge into `feat/package-installer` | `5f53630` / `f5e173d` |
| PR #3 `fix/interpretation-integrity` head / merge | `26c01c1` / `588ddb8` (tree identical to the tested integration merge `6d7805f`) |
| Added on PR #3 this session | `3e6159a` (save-bundle tests R-a..R-d), `26c01c1` (C1-01 fix) |
| This slice, `feat/read-page-candidates` on `588ddb8` | `71a427f`, `dba5b31`, `b763c06`, `04a691f`, `cbd1954`, `78ab62f`, `717758b`, `a31bd30` |
| `main` | untouched at `10372cf`. Draft PR #4 (`feat/package-installer` -> `main`, 28 commits, 132 files) is open and not merged |

No GitHub workflows, rulesets, branch protection or webhooks exist. `actions/runs` was 0 after every push and merge.

**Verification of the merged work.** The baseline totals were reproduced at the exact SHAs: 53 (`5f53630`), 85 (`9e32531`) and 102 (integration `50de634`). After `3e6159a` and `26c01c1` the totals are 90 (`26c01c1`) and 107 (`6d7805f`). The R-a..R-d save-path tests run against the same `PreconProjectStore.saveRevision` that `TakeoffController.save` calls, with fault injection:
- R-a: the user's exact three-save R1 sequence.
- R-b: a changed retry gets a fresh ID.
- R-c: abandoned R2 files are SHA-256-identical before and after, and unreferenced.
- R-d: reopen validates every binding and refuses isolated tampering.

Your manual walkthrough (calibrate, trace, save/retry, quit/reopen, incompatible-scale refusal) is recorded as user-tested workflow evidence, not as acceptance. `verify_package.py` fails in `mlx-local-interp` only because of an untracked, git-ignored Finder `.DS_Store`. It passes on a `git archive HEAD` export.

**Codex findings and resolution** (`codex-review-1.md` .. `codex-review-5.md`)

| ID | Severity | Resolution |
|---|---|---|
| C1-01 | Material | A changed retry could reuse a partially used revision ID when no filenames collided. Fixed in `26c01c1` with `canReuseRevisionID`, verified in review 2. The red run was a compile failure (C2-01) |
| C1-02 | Note | A load/eviction window predates this work (a model is resident with 0 active requests while its callback runs). Open |
| C1-03 | Note | Controller-only paths are untested (native target). Open |
| C3-01 | Material | Over-threshold profiled prompts hit the backend's chunking branch, which drops the profile and output cap. Fixed in `b763c06`: such prompts are refused before `execute` |
| C3-02 | Minor | The advisory gate checked models the current stage doesn't use. Removed in `b763c06` |
| C3-03 | Note | Cache identity depended on the caller. Fixed: the `adapter.pipeline(...)` factory binds `profileDigest` |
| C4-01 | Material | Cancel didn't release a reader waiting on a cold load. Fixed in `78ab62f` with a cancellation race; the shared load is not stopped |
| C4-02 | Minor | Crop work ran on the main actor. Fixed in `717758b` |
| C4-03 | Note | Eval negative controls are exact-match sentinels. Documented |
| Architect | Material | The runner ignored live memory. Fixed in `a31bd30` with a live vm_stat budget. The pre-check now proceeds when available + idle reclaimable >= estimate |
| C5-01 | Minor | Qwen3-VL-8B is registered vision-only, so the eval's OCR stage can't use it. The user switched the real run to dots.ocr. Open: the runner preflight should require the capability that is actually used |

**Slice design** (`slice-spec.md`):
- `PreconRuntimeInterpreter` sends one local-only, structured stage to the model the user picked, through the shared `ModelResourceManager`.
- `ResourceManager.swift` and `LocalInferenceBackends` are unchanged. Wrapped `execute` errors become `runtimeFailed`, and the unit fails closed.
- Read Page has no preselected model and does not run on launch. Accept/Reject writes a write-once, digest-bound review record and never a quantity. Stale reviews are shown, never applied.
- `PreconEvaluation` refuses to run without `--authorized` and installed model IDs.
- The eval set has 4 native-text synthetic PDFs plus 1 raster page. Its expected results were written from the generator inputs; Codex re-derived two of them independently. It scores four separate metrics.
- Final suite at `a31bd30`: 133 tests (`c4fix-final.log`, exit 0). Codex's independent run also passed (`codex-review-5-tests.log`).

**Real model vs mock.** All S01-S12+ tests and S11 use fakes (MOCK). There was one real run, authorized by the user with the quiet window confirmed: `PreconEvaluation --authorized --text-model mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit --image-model mlx-community/dots.ocr-8bit` at `a31bd30`, 2026-10-26 19:03:44Z to 19:04:04Z, exit 0. The report is `real-eval-report.json` and the run log is `real-eval-run.log`. After the run no worker processes remained and memory was released.

| Metric | Result |
|---|---|
| Extraction | 10/21 expected items found |
| Source support | 14/14 candidate quotes verbatim on the page |
| Coverage | 4/5 pages interpreted. The raster page failed: dots.ocr returned malformed output twice (initial call and one retry), so it fails closed |
| Quantity agreement | 2/2 (deterministic geometry only; candidates are never counted) |
| Absent-item trap / no-quantity page | No absent item was found; 0 candidates |

That is one run on five synthetic pages, which shows the integration path works. It does not establish accuracy, and the OCR prompt/model pairing is not working yet. Neither the native UI nor Read Page has been run against a real model. No vision-stage (crop) inference has been run.

**Untested or open**
- The native app: Read Page, candidate review, and the save/retry walkthrough below after the C1-01 fix.
- C1-02.
- After a cancelled shared load completes, `runtime.execute` may still be entered. Only URLSession cancellation stops it. A one-line `Task.checkCancellation()` after `ensureLoaded` in `executeStage` would close this. It touches the merged manager, so it needs approval and review.
- Measured memory peaks.
- Same-sign touching polygons.
- A11.

## Next steps (in order)

0. **Open gate: running-app save/retry walkthrough (about 5 minutes, needs a person).** The closeout session couldn't drive the UI (no Accessibility permission). Use a debug build of this branch and a throwaway data root:
   1. `PRECONSTRUCTION_WORKSPACE=<empty dir> PRECONSTRUCTION_TEST_FAIL_SAVE=revisions,checkpoints "$(swift build --show-bin-path)/MLXMenu"`. The seam is compiled into debug builds only. It fails the first write into `revisions/`, then the first write into `checkpoints/`, once each.
   2. Open Takeoff, create project `Walk`, and import `Preconstruction/fixtures/synthetic-plan.pdf`. Cal X: 12 ft from (100,300) to (316,300). Cal Y: 10 ft from (110,200) to (110,380). Trace area 100,200 / 316,200 / 316,380 / 100,380. The panel should show 120 SF.
   3. Click Save. Expect "Injected test failure before writing revisions/R1.json". `measurements/` holds R1 files; `revisions/` and `checkpoints/` hold none.
   4. Click Save again without editing. Expect "Injected test failure before writing checkpoints/R1". `revisions/R1.json` now exists; there is still no checkpoint.
   5. Click Save a third time. Expect "Saved R1 with checkpoint." The project holds exactly one `R1-*-measurements.json` and one `R1-*-plane.json`, with no copies.
   6. Partial-write case with changed content: quit, relaunch with `PRECONSTRUCTION_TEST_FAIL_SAVE=checkpoints`, and reopen `Walk`. Expect R1 at 120 SF. Trace a 2x3 ft deduction (154,254 / 190,254 / 190,308 / 154,308). Click Save: it fails at `checkpoints/R2`, leaving the R2 measurement and revision files. Delete the deduction (the content changes), then Save. Expect "Saved R3 with checkpoint. An earlier failed save left R2-... for R2 with different content; it was not overwritten." The R2 files stay byte-identical and unreferenced.
   7. Quit, relaunch without the variable, and reopen `Walk`. Expect "Reopened Rn from verified checkpoint" showing the last saved geometry. The newest checkpoint's `measurement_digests` must list only that revision's files.
   8. A11 refusal check: on the same page, choose Cal X, enter 6 ft and click the same two points. Expect the "traced at 18.000 pt/ft ... not supported (A11)" message, with the area unchanged.
1. Done: `build-package.sh` built `dist/MLX-Menu-3.1.1.5.pkg` (unsigned) and `verify-package.sh` passed with the template allowlist. The app extracted from the pkg, launched from cwd `/`, created a project identical to its bundled template. Not installed; installing needs admin rights.
2. Touching same-sign polygons (rooms sharing a wall) need a Boolean polygon engine to decide; until then that pair stays `unavailable`.
3. Done in Session 6: the runtime adapter, the ResourceManager admission/cancellation wiring, Read Page with candidate review, and the held-out eval set and runner. Remaining before merging `feat/read-page-candidates` (draft PR, not merged):
   - Native walkthrough of Read Page. Select models, read a native-text page, Cancel during a cold load, Accept/Reject, then edit the source and confirm the review shows as stale. Needs a person and a quiet window.
   - C5-01: require the capability the stage actually uses in runner preflight, and make the OCR prompt work with dots.ocr (or use Apple Vision OCR). Rerun the real eval after that.
   - Optional, needs approval: the one-line cancellation check after `ensureLoaded` in `ResourceManager.executeStage`.
4. Next bounded milestone toward document-set takeoffs: **project-level read across a document set.** Run Read Page over every page of every imported source. Group the reviewed candidates by sheet, room and spec section. Surface conflicts between sources (the same dimension or material stated differently) and unresolved questions as first-class records. Candidates stay candidates: quantities still come only from deterministic measurement, and conflicts are never auto-closed. Exit: a synthetic 2-3 sheet set with a planted plan/schedule conflict and a missing spec item. The conflict and the question must be reported with sources, with zero invented quantities.

## Rules and gotchas

- Don't add or edit files under `Preconstruction/`. `verify_package.py` checksums every file there.
- Run the package's Python with `python3 -B`, not `-I`. `-I` ignores `PYTHONDONTWRITEBYTECODE` and drops the script directory from `sys.path`, so imports fail and `__pycache__` breaks verification.
- Run tests with `nice -n 10` on this shared Mac. Never run installs, model loads, benchmarks, the V3 tracer, cloud calls or pushes without asking.
- Commit only when asked. Commit messages: imperative, about "why", ending with the Co-Authored-By trailer.
- A corrupt `interpretation/<id>.json` or checkpoint throws `PreconProjectError.corrupt` (not `staleCheckpoint`); files are write-once, so delete it by hand to rerun that unit.
- `InterpretationUnit.status` is a summary (a budget gap shows `partial` even if candidates are held); check each candidate's `heldReason` and the unit's `coverage`.
- Unknown values stay nil and are never zero. Model output can only ever be a candidate, never accepted geometry. Approvals bind a snapshot digest.
