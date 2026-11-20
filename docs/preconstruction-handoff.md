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
  - Topology (since Session 9): every pair is decided, so the result is `.passed` or `.failed`, never `.unavailable`. Same-sign polygons that share area fail (crossing, nested, repeated, or inscribed), except an add-back (a positive polygon inside a deduction of its zone). Polygons that only touch along a wall or corner pass. A deduction or add-back may touch the boundary of the polygon that contains it; it fails only when part of it lies outside.
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
| This slice published | draft PR #5 (`feat/read-page-candidates` -> `feat/package-installer`), not merged |

The core evidence (`slice-core.md`, `slice-core-*.log`) was produced at `d6ca0de`/`974351d` on top of the integration tree `6d7805f`. Those commits were then rebased onto `588ddb8` as `71a427f`/`dba5b31`, with identical trees. `/Users/mccully/projects/mlx-local-review` is a detached snapshot worktree that Codex reviewed from; it was left at `a31bd30`.

Beyond routing, the coordinator (Claude) did these directly:
- merged PRs #2 and #3, and opened PRs #4 and #5;
- rebased this branch;
- ran the one authorized `PreconEvaluation` command;
- wrote this Session 6 section.

The original Codex pane was shut down by a mistaken interrupt keypress while its hooks prompt was being answered, so all reviews ran as fresh supervised Codex sessions.

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
| C5-01 | Minor | Qwen3-VL-8B is registered vision-only, so the eval's OCR stage can't use it. The user switched the real run to dots.ocr. Fixed in Session 7 (`cb4b0a9`, `e506c5e`) |

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

## Session 7 (2026-11-19): C5-01 closed, OCR page read by a real model

- `cb4b0a9`: runner preflight (`PreconEvaluationOptions.preflight`) refuses an image model without OCR, image input and structured output before any runtime is built.
- `e506c5e`: the scanned page could never be read, whatever the model. `OpenAIWorkerRuntime` returns OCR as `## Page 1` markdown, and the pipeline decoded it as JSON. `PreconRuntimeInterpreter` now sends OCR with no instruction (the runtime's fixed prompt), strips the page header and builds `{"text","confidence"}` itself. The confidence is the runtime's line-uniqueness/length score, not a model probability. `ocrContract` is part of the profile digest, so units from the old mapping are not reused. The pipeline's `ocrInstruction` is not sent on this path. S08's fake now returns the real artifact shape; it failed before the fix.
- 136 tests pass at `e506c5e`.
- dots.ocr-8bit does not read text under mlx-vlm 0.5.0 on this Mac. Probed directly on a scratch image (not the eval set): the standard OCR prompt returns `content: null`; a JSON prompt returns one `Picture` box. That bogus JSON was the "malformed output" of the Oct 26 run. PaddleOCR-VL-1.6-4bit and OvisOCR2-8bit both transcribed the same scratch image correctly.
- Two real runs at `e506c5e`, text model Qwen3-30B-A3B-Instruct-2507-4bit, reports in `/Users/mccully/projects/mlx-local-evidence/2026-11-19/`. No workers were left running after either.

| Metric | dots.ocr-8bit (`real-eval-report.json`) | PaddleOCR-VL-1.6-4bit (`real-eval-report-paddleocr.json`) |
|---|---|---|
| Extraction | 10/21 | 11/21 |
| Source support | 14/14 | 14/18 (the 4 OCR candidates can't count: no native text) |
| Coverage | 4/5 pages; the scan deferred (worker returned empty content) | 5/5 pages, 5/5 chunks |
| Quantity agreement | 2/2 | 2/2 |
| Absent-item trap | none found | none found |

The scanned page gave 4 candidates (`A105 Room`, `Pine`, `18 ft`, `Finish concrete`), all held for a source-image check as designed. Only `18 ft` matches an expected item exactly. Extraction is still about half; nothing was tuned against this set. Two runs on five synthetic pages show the path works, not accuracy.

Still not done: the native Read Page walkthrough, any vision-crop inference, and the save/retry walkthrough after C1-01. PRs #5 and #4 were merged at the user's direction with those recorded as untested. (Superseded for the two walkthroughs: see Session 8.)

## Session 8 (2026-11-19): extraction pass (PR #6, merged to `main` as `d3a6d55`)

- **Walkthroughs.** The user reports having done both the save/retry and the Read Page walkthroughs and believes both passed. Nothing was captured (see Next steps 0 and 3).
- **Label convention** (user decision for rooms and materials; the rest is the same rule extended, stated in `Fixtures/precon-eval/README.md`): a candidate's text is the bare value. Room `Cedar` not `Room Cedar`; material `oak` not `Finish oak`; dimension `12 1/2 ft` without `Width`; a note is the whole line verbatim; a sheet is the bare ID.
- **Evaluation sets.** The old held-out pages had been read item by item, so they were relabelled and moved into a new dev set, `dev.json` (20 pages, 85 items, 3 scans). `expected.json` is a fresh held-out set (`synthetic-held-out-v2`, 5 pages, 22 items), written before any tuning. Both now list table headers and sheet-ID look-alikes (`D104`, `M10`, `R2`) as `absent` traps, because the extraction metric is recall-only.
- **Sheet IDs are deterministic.** `InterpretationPipeline.sheetIDs(in:)` reads IDs like `A101`, `A-101`, `S2.1`, `A1.01` at the start of a line of page text and adds them as `sheet` candidates with a nil confidence (offered on native text, held on scans). The model is told to skip sheet numbers. Known ceiling: a door or equipment tag alone on a line still matches, and IDs inside a sentence are skipped. Not applied to vision crops.
- **New default candidate instruction** with per-kind rules and one worked example. A test keeps the example's values out of both fixtures. It reaches the runner and Read Page (both use the default). The same instruction goes to vision crops, which have still never run against a real model.
- Pipeline version is `precon-interpret-7`; units saved under 6 are not reused.
- **Real runs**, Qwen3-30B-A3B-Instruct-2507-4bit + PaddleOCR-VL-1.6-4bit, reports and logs in `/Users/mccully/projects/mlx-local-evidence/2026-11-19/`:

| Run | Extraction | Trap items found | Wrong extras | Pages |
|---|---|---|---|---|
| Dev, unchanged pipeline (`dev-baseline-1`, `-2`, identical) | 50/85 | 3 | 26 | 20/20 |
| Dev, after the change (`dev-tune-1`, the only tuning run) | 82/85 | 0 | 3 | 20/20 |
| Held-out v2, run once (`heldout-v2-final`) | 22/22 | 0 | 1 | 5/5 |

  Dev misses left: a scanned notes page whose two notes came back merged into one candidate, and one status note skipped. The extras are whole lines offered as notes (`Rev R2`, `See detail 4 on A-501`, `Door D212 existing`).
- **Limits.** Both sets come from the same generator and the same author, with one line per item in an 18 pt font. 22/22 says the instruction and convention work on that layout; it says nothing about real drawings. Held candidates count toward extraction, and scanned-page candidates are all held.
- **Held-out v2 is now spent.** Its per-case output was read after the run (the `Door D212 existing` extra above), so write fresh held-out pages before any further tuning.
- **Confidence is not informative under this prompt.** Every model candidate in both runs came back at 0.9, the value in the worked example (earlier runs returned a flat 1), so the 0.6 low-confidence hold never fires. Left as is, because changing the prompt would invalidate the held-out run.
- Deterministic sheet candidates are the first *offered* candidates with a nil confidence. Read Page's row code prints `Confidence: unknown` for nil; not looked at in the running app.
- The run logs record a diff hash taken before the handoff and README edits; Sources and the fixture JSON did not change after the runs.
- 139 tests pass.

## Session 9 (2026-11-19): shared-wall topology (`feat/shared-wall-topology`, branched from `main` `d3a6d55` after PR #6 merged)

- `Takeoff.boundary(of:against:)` cuts each edge of one polygon at the other's vertices and classifies every piece as along the other's boundary, inside it or outside it. `overlaps` and `contains` are built on it; `touches`, `relation` and the `undecided` list are gone. This closes "touching same-sign polygons" (F12, Next steps 2) and replaces N03's strict-containment rule with an exact one: N03's notch case now fails outright instead of staying unavailable.
- Behaviour changes: rooms sharing a wall or corner pass; deductions sharing an edge pass; a deduction against a wall and an add-back on its deduction's edge pass; the same outline with an extra collinear vertex and a polygon inscribed with every vertex on the other's edges now fail as overlaps.
- Tests: 143 pass. New cases cover nine shared-wall shapes, diagonal walls, boundary containment, and 600 random rectangle and L-shape pairs checked against independent grid-cell counting for both overlap and containment.
- **Limits.** A point counts as on an edge when it is within 1e-9 of the edge's size; an independent review found that the first, exact test let a real overlap pass on a diagonal wall with decimal coordinates (and gave false overlaps when the same shapes were rotated), so the 600-pair test now also runs rotated. Slivers thinner than that band are misjudged, which fuzzing only reached with edges over 30,000 units long. A deduction straddling two adjacent rooms still fails, because it must sit inside one gross polygon. The random check covers axis-aligned shapes only.
- **No vertex snapping in the UI.** Clicks are rounded to 0.01 pt and never snap to an existing vertex or edge, so two rooms traced by hand along the same wall will usually be a hair apart (passes) or a hair overlapping (fails). Shared walls are only exact when coordinates coincide. Snapping is the follow-up that makes this useful in the app; not built.

## Session 10 (2026-11-19): first real plan set, and the reading fixes it forced (`feat/real-sheet-reading`)

A real 17-sheet residential remodel set (36 x 24 in, native text on every sheet) was run through the Read Page pipeline with the text model only, five times as fixes went in. The set, its outputs, raw model answers and logs live outside the repo in `/Users/mccully/projects/mlx-local-evidence/` (`plan-sets/` and `2026-11-19/real-sheet-trial/`); `plan-sets/` is git-ignored here. Nothing from the set is in the repo, and nothing from it may be added: this repo is public.

**What went wrong on real sheets (each confirmed from raw model output)**
- **A bad answer stopped the whole run.** The resource manager's own JSON check threw on invalid output, the adapter wrapped that as a runtime failure, and the pipeline recorded a deferral, which halts the run. The pipeline's "malformed after retry, fail the page" path (A22) never ran on the real runtime. With the old defaults the run stopped at sheet 3.
- **Output overran the budget** (`finish_reason: length`, well-formed JSON cut off). Three separate causes:
  1. Verbose candidates: each repeated its text as a quote and carried `confidence` and `bbox`.
  2. A quote rule tried during this session made it worse: on a line holding ten dimensions the model repeated the whole line as the quote ten times. Quotes are no longer requested.
  3. **Repetition loops.** The model repeats one candidate until the budget runs out (one answer was the same material 324 times). It happens on sheets where a string is printed many times, and which sheet it hits changes from run to run, even at temperature 0.
- The title block came back as notes on every sheet, and the first deterministic sheet-ID pattern matched none of this set's IDs (a short word, a dot and a digit).

**Changes**
- **Failure handling.** No stage asks the manager for structured output. The pipeline decodes (the whole output, the outermost JSON object, or an answer missing only its closing brace), retries once, and fails that page only. Cut-off output is recognised and not retried. S01's assertion on the structured-output flag was changed to match.
- **Compact output.** The instruction asks for `kind` and `text` only, on one line. `quote`, `confidence` and `bbox` are no longer requested.
- **Two reviewed holds changed** (A17's expectations were edited; independently reviewed, see below). A candidate with no quote is checked against the source by its own text instead of being held as "no source quote", and its stored quote stays null. That text must sit on one source line or be whole consecutive lines. A candidate with no confidence is no longer held as "low confidence"; a stated confidence under 0.6 still is.
- **Budget.** Chunks are bounded by lines as well as characters. Defaults are 1,500 characters, 60 lines, 12 chunks and 3,072 output tokens (were 6,000 / no line bound / 4 / 1,024). `maxInputLines` is in the unit ID.
- **Distinct lines.** Each distinct line of a page is sent to the model once, with the number of repeats left out recorded in coverage, and a candidate with the same kind, text and quote is kept once.
- **Title block.** In a PDF of 5 or more pages, a line printed on at least four of every five pages is skipped and counted in the unit's coverage. Set-wide status notes ("not for construction") go with it and are no longer candidates on any sheet. Read Page shows that coverage line as its message on multi-sheet sets.
- **Sheet IDs.** On a native-text page the ID is the ID-shaped line nearest a `SHEET:` label line by position (or the ID on the label's own line), because the text layer lists title-block strings in drawing order. From text alone (scans) it is the token beside the label. The line-start pattern is used only when a page has no label. The ID's line is not sent to the model, and a failed page still reports its sheet.
- Pipeline version is `precon-interpret-9`. The eval's source-support metric counts an unquoted candidate by its own text.

**Results**

| | Before | After |
|---|---|---|
| Dev set extraction | 82/85 | 84/85, no trap items, 2 extras, nothing held (`dev-review-2`) |
| Real set, sheets read | stopped at sheet 3 with defaults; 9 of 17 with enlarged settings in 16 min | 16 of 17 with defaults in 5 min (`run-7`); the failed sheet keeps 65 candidates |
| Real set, sheet IDs | 3 of 17, plus 12 wrong | 17 of 17 |
| Real set, candidates | 362 from 9 sheets, title block included | 807 from 17 sheets, 27 held |

The real set is now a tuning set: these are counts, not accuracy. The dev set has single pages and no `SHEET:` labels, so it says nothing about the title-block or sheet-ID rules; those rest on this one plan set and on mock tests.

**Still wrong on the real set**
- One sheet still fails to a repetition loop in the last run, and the affected sheet varies between runs (intermediate runs lost between one and four sheets). The loop itself is not fixed; its cost is smaller, because the candidates an answer finished before the cut are kept and the page's other chunks are still read. The page stays `failed`, so it is not saved and a re-read tries again. Not yet tried: a repetition penalty on the generation settings.
- Content quality is poor. Of the 807 candidates, 117 are three characters or fewer, and kinds are misused (equipment, fixtures and circuit labels as rooms or materials). Real sheets carry schedules, legends, keynotes and equipment that the four kinds don't describe. The synthetic sets predicted none of this.
- A few title-block lines leak where a line wraps differently on some sheets.
- Only 27 candidates were held; the rest were offered, so the holds filter almost nothing here.
- The held-out synthetic set is spent and was not rerun; the prompt changed, so its earlier 22/22 no longer applies.
- Vision crops get the same compact instruction and have still never run against a real model.
- Open product question for the user: what should be extracted from a real sheet.

**Independent review of this branch (2026-11-20) and what was done about it**

Fixed, each with a test:
- The sheet-ID rule took the first `SHEET:` text anywhere, so a note such as "SEE SHEET: ..." beside a tag made the tag the sheet ID. A label is now a line holding nothing but the label, or the label and its ID.
- An unquoted candidate could be assembled from words on neighbouring lines. It must now sit on one line or be whole consecutive lines (a wrapped note). Candidates are checked against the page without its title block.
- Lines shared by some sheets (three of five) were treated as title block. The share is now four in five; on the real set every title-block line was on 14 or more of 17 sheets and nothing else on more than 6.
- A closed answer with a badly quoted string was reported as a budget cut-off and not retried; an empty answer missing its closing brace failed the page.
- One candidate of an unknown kind or shape failed the whole chunk. It is now skipped and counted in coverage.

Tried and reverted: sending every line except back-to-back repeats, to stop wrapped notes losing a shared line. Loops came back (4 of 17 sheets failed, against 1), so distinct lines stay and the repeats are counted in coverage. A wrapped note whose last line also ended an earlier note still reaches the model without that line.

Left as they are:
- From text alone, a label whose ID is not on its line or the next gives no ID. The review wanted the line-start pattern as a fallback; that would offer code references as sheet IDs, and no ID beats a wrong one.
- The adapter and preflight still require a model's structured-output capability (C5-01), although the manager is no longer asked for structured output.
- The retry sends the same prompt (`isRetry` is unused by the adapter). It helps only because the model's output varies between runs.
- The eval's source-support metric uses a plain substring test and ignores holds.
- A held low-confidence candidate stays held if the same text arrives again with a higher confidence.

## Next steps (in order)

0. **Save/retry walkthrough: the user reported on 2026-11-19 that they had done it** and believe it passed (Session 6 also records a manual walkthrough as user-tested). No run date, build SHA or log was recorded, so it is user-reported evidence, not a captured result. The steps are kept for reruns. Original text: the closeout session couldn't drive the UI (no Accessibility permission). Use a debug build of this branch and a throwaway data root:
   1. `PRECONSTRUCTION_WORKSPACE=<empty dir> PRECONSTRUCTION_TEST_FAIL_SAVE=revisions,checkpoints "$(swift build --show-bin-path)/MLXMenu"`. The seam is compiled into debug builds only. It fails the first write into `revisions/`, then the first write into `checkpoints/`, once each.
   2. Open Takeoff, create project `Walk`, and import `Preconstruction/fixtures/synthetic-plan.pdf`. Cal X: 12 ft from (100,300) to (316,300). Cal Y: 10 ft from (110,200) to (110,380). Trace area 100,200 / 316,200 / 316,380 / 100,380. The panel should show 120 SF.
   3. Click Save. Expect "Injected test failure before writing revisions/R1.json". `measurements/` holds R1 files; `revisions/` and `checkpoints/` hold none.
   4. Click Save again without editing. Expect "Injected test failure before writing checkpoints/R1". `revisions/R1.json` now exists; there is still no checkpoint.
   5. Click Save a third time. Expect "Saved R1 with checkpoint." The project holds exactly one `R1-*-measurements.json` and one `R1-*-plane.json`, with no copies.
   6. Partial-write case with changed content: quit, relaunch with `PRECONSTRUCTION_TEST_FAIL_SAVE=checkpoints`, and reopen `Walk`. Expect R1 at 120 SF. Trace a 2x3 ft deduction (154,254 / 190,254 / 190,308 / 154,308). Click Save: it fails at `checkpoints/R2`, leaving the R2 measurement and revision files. Delete the deduction (the content changes), then Save. Expect "Saved R3 with checkpoint. An earlier failed save left R2-... for R2 with different content; it was not overwritten." The R2 files stay byte-identical and unreferenced.
   7. Quit, relaunch without the variable, and reopen `Walk`. Expect "Reopened Rn from verified checkpoint" showing the last saved geometry. The newest checkpoint's `measurement_digests` must list only that revision's files.
   8. A11 refusal check: on the same page, choose Cal X, enter 6 ft and click the same two points. Expect the "traced at 18.000 pt/ft ... not supported (A11)" message, with the area unchanged.
1. Done: `build-package.sh` built `dist/MLX-Menu-3.1.1.5.pkg` (unsigned) and `verify-package.sh` passed with the template allowlist. The app extracted from the pkg, launched from cwd `/`, created a project identical to its bundled template. Not installed; installing needs admin rights.
2. Done in Session 9: touching polygons are decided without a Boolean engine. Open follow-up: the takeoff view has no vertex snapping, so hand-traced adjacent rooms rarely touch exactly.
3. Done in Session 6: the runtime adapter, the ResourceManager admission/cancellation wiring, Read Page with candidate review, and the held-out eval set and runner. PR #5 is merged. Status of what was listed as remaining:
   - Read Page walkthrough: the user reported on 2026-11-19 that they had done it and believe it passed; no run date, build SHA or log. It is not known whether it was run after `e506c5e`, so reading a scanned page in the app with a working OCR model (PaddleOCR-VL or OvisOCR2) may still be unwalked.
   - Done in Session 7: C5-01. Use PaddleOCR-VL-1.6-4bit or OvisOCR2-8bit for OCR; dots.ocr-8bit returns nothing here.
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
