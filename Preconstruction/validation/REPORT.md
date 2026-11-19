# Package validation — 2026-10-19

This report validates a staged handoff package. It does not claim the mlx-local preconstruction feature, production accuracy or real-project measurements are implemented.

| Check actually executed | Result | Evidence/limit |
|---|---|---|
| `python3 tests/test_contracts.py` | 10 passed | Original helper arithmetic versus dimensions, route/count identity, source hashes/references, unknown/retained/pending states, calibration conflict fixture, crop inverse, plain text and schema/template separation |
| `python3 skills/plan-area-takeoff/scripts/test_geometry.py` | 10 passed | Imported deterministic area helper regression tests; no drawing interpretation or inter-polygon topology |
| Existing Anaconda `python .../test_cad.py` | 20 run: 19 passed, 1 skipped | Synthetic CAD inspect/extract/render/annotation/source-preservation tests; actual DWG round-trip skipped because TAKEOFF_TEST_ODA was not enabled. PyMuPDF/Swig deprecation warnings did not fail the suite |
| Existing Anaconda `python tests/test_optional_checks.py` | 5 passed | Draft 2020-12 schema/instance, independent Boolean net 114 SF with one hole, invalid topology fixtures, vector/scan/crop frame checks, actual rendered SVG hole pixel clear |
| Synthetic PDF/raster checks | Passed | One text/vector PDF opens, contains dimension text; generated scanned PDF contains no extractable text; known crop is 432 × 360 pixels |
| Manual rendered synthetic overlay inspection | Completed | Viewed final SVG rendered through PyMuPDF; visible clear island hole, room fill, legible legend, disclosed material conflict and pending review. This is an illustrative fixture, not a production PDF overlay exporter |
| Original source preservation | Passed | 145 inspected source hashes unchanged, 75 packaged-source originals match recorded input hashes, mlx-local dirty status unchanged. See preservation-and-privacy.json |
| Bounded privacy review | Passed | Allowlisted shared skills/templates/helpers only, known customer/history identifiers absent from package text, secret-signature scan, no customer source files copied. Tripwires are not an exhaustive privacy certification |
| Package integrity and archive | Passed when final verify/archive command exits 0 | Source/package hashes, JSON/Python syntax, local Markdown links, safe ZIP paths, full readback/CRC and byte comparison; archive checksum supplied alongside ZIP |

45 tests ran across four suites: **44 passed and one explicitly skipped**. These tests do not establish full A01–A40 application acceptance. The optional tests use existing packages only. Core checks need the Python standard library.

## Not run or not established

- No local-model inference, OCR/VLM extraction, live server health test, model loading, new workers, heavy benchmark, installs, Swift builds/test suites, expensive V3 tracer or Prime/Claude startup.
- No actual DWG conversion; ODA availability alone is insufficient.
- No production overlay/workbook exporter, formula recalculation, full app source-interpretation/coverage or UI integration test. The client/internal examples are fixed synthetic drafts.
- The saved registry is dated 2026-10-06; it is not live health/residency or memory availability. Current hardware/memory sysctl was denied by the environment. No escalation was needed for packaging; the architecture requires runtime admission and explicit resource caps.
- No live code/jurisdiction research or refreshed legal/product/standard advice. Source registries retain their dated authoring claims and must be verified before project-specific binding conclusions.

The area helper deliberately reports topology and source correspondence as unchecked. The package includes a test showing an out-of-bounds equal-area deduction still passes arithmetic, plus independent Shapely tests that detect invalid topology fixtures. Production release must implement and preserve those separate gates.
