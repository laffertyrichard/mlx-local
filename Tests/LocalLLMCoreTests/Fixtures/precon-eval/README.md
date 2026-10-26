# Synthetic interpretation evaluation

`expected.json` was written by hand from the page-generator inputs before any interpreter run. Four pages draw native text; the fifth rasterizes its text before embedding it in a PDF (no text layer). The fraction, exclusion, non-quantity note and schedule are deliberate. `absent` items are negative controls, never page content. Geometry dimensions and expected areas are independent generator inputs, not extracted quantities.

The test interpreter is scripted and labelled MOCK. These small cases are held out from prompt tuning, not evidence of model accuracy. Run the explicitly authorized PreconEvaluation command separately for real-model evaluation; no real run is part of the implementation task.

## Separate authorized real run (not run during implementation)

From the repository root, after building: `.build/debug/PreconEvaluation --authorized --text-model <installed-id> --output <new-report.json> [--image-model <installed-id>] [--dataset <expected.json>]`.

No arguments, missing authorization, missing output, unknown flags, missing installed models or missing runtime executables refuse. The executable never downloads models. It creates a disposable data root, keeps inference evidence separate from takeoff, writes an exclusive report, and shuts down its own runtime manager. The output path must not exist; its parent must exist. Real execution needs user authorization and a quiet machine.

Metrics stay separate: exact expected-item extraction recall; literal native-source quote support (OCR does not validate itself); interpreted/skipped pages and chunks; deterministic area agreement using the two known rectangles. Absent-item detections are a separate negative-control list. No extraction or review decision contributes to the area metric. Missing denominators or unknown chunk counts are reported unavailable. These metrics do not certify construction accuracy.
