# Synthetic interpretation evaluation

Two sets, same generator:
- `dev.json` (`synthetic-dev-v1`, 20 pages): for tuning prompts and rules. Its first five cases are the original held-out pages, moved here after their results had been read item by item.
- `expected.json` (`synthetic-held-out-v2`, 5 pages): held out. Run it once after tuning and report the score; if you read its per-item results, replace it.

Both were written by hand from the page-generator inputs before any interpreter run on them. Scans rasterize their text before embedding it in a PDF (no text layer). `absent` items are negative controls, never page content as a candidate: unrelated values, table column headers, and sheet-ID look-alikes such as door tags. Geometry dimensions and expected areas are independent generator inputs, not extracted quantities.

Label convention (exact match): room is the bare name (`Cedar`, not `Room Cedar`); material is the bare material (`oak`, not `Finish oak`); dimension is the value with units and no label (`12 1/2 ft`); a note is the whole line verbatim; a sheet is the bare ID (`A-101`).

The worked example in `InterpretationPipeline.candidateExample` must share no value with either set (tested).

The test interpreter is scripted and labelled MOCK. Neither set is evidence of model accuracy on real drawings. Run the explicitly authorized PreconEvaluation command separately for real-model evaluation (`--dataset` selects the set).

## Separate authorized real run (not run during implementation)

From the repository root, after building: `.build/debug/PreconEvaluation --authorized --text-model <installed-id> --output <new-report.json> [--image-model <installed-id>] [--dataset <expected.json>]`.

No arguments, missing authorization, missing output, unknown flags, missing installed models or missing runtime executables refuse. The executable never downloads models. It creates a disposable data root, keeps inference evidence separate from takeoff, writes an exclusive report, and shuts down its own runtime manager. The output path must not exist; its parent must exist. Real execution needs user authorization and a quiet machine.

Metrics stay separate: exact expected-item extraction recall; literal native-source quote support (OCR does not validate itself); interpreted/skipped pages and chunks; deterministic area agreement using the two known rectangles. Absent-item detections are a separate negative-control list. No extraction or review decision contributes to the area metric. Missing denominators or unknown chunk counts are reported unavailable. These metrics do not certify construction accuracy.

Negative controls are exact-match sentinels; not a general hallucination detector.
