---
name: plan-area-takeoff
description: Use when measuring, reviewing or revising scope-matched takeoffs from PDF, DXF or DWG plans, scans, elevations, schedules, design sets and specifications; comparing existing/proposed work; assessing depicted infrastructure reuse; or preparing quantity changes and material order estimates. Applies to finishes, structure, demolition/restoration, openings/glazing, waterproofing, stairs/railings, sitework and depicted MEP. DWG needs a working converter; concealed routes and missing designs remain unestablished.
---

# Building Plan and Scope Takeoff

Use one measurement manifest as the authority for polygons, line routes, counts, dimensional inputs, overlays, and schedules. Treat quantity arithmetic, geometry interpretation, and scope certainty as separate questions. A good-looking overlay or matching spreadsheet total does not prove the plan was interpreted correctly.

## Scope and reference routing

Build a room-by-trade coverage list from the user's request and the supplied sheets. Distinguish measured, provisional, existing retained, excluded, and not established. An absent symbol or detail means unknown, not zero. Do not expand a flooring-only request into every supported trade. When all flooring is requested, include every in-scope finish, not only tile; reconcile halls, closets, recesses, thresholds and hearths.

Always read [references/design-coordination.md](references/design-coordination.md) for source cross-referencing, callout coverage and questions. Apply the review to the requested scope; a single supplied file still requires checking its relevant views and recording missing referenced sources.

Read the other references needed for the requested scope:

| Scope | Reference |
|---|---|
| DXF/DWG intake, CAD units/layers/blocks/xrefs, conversion and CAD overlays | [references/cad-intake.md](references/cad-intake.md) |
| Scope-of-work matching, whole-set review and depicted MEP limits | [references/scope-matching.md](references/scope-matching.md) |
| Concrete, footings, slabs, reinforcing, masonry, framing and hardware | [references/concrete-and-framing.md](references/concrete-and-framing.md) |
| Drywall, paint, insulation, stucco, roofing, soffits and trim | [references/building-finishes.md](references/building-finishes.md) |
| Existing/as-built versus proposed plan alignment and comparison overlays | [references/plan-comparison.md](references/plan-comparison.md) |
| Flooring and supported-footprint deductions | [references/flooring.md](references/flooring.md) |
| Cabinet LF, doors, drawers and panel distinctions | [references/cabinetry.md](references/cabinetry.md) |
| Wall tile, exposed edges and shampoo niches | [references/tile-and-niches.md](references/tile-and-niches.md) |
| Countertop tops, solid-surface backsplashes and slab fabrication faces | [references/slab-surfaces.md](references/slab-surfaces.md) |
| RCP decorative ceiling LF and electrical symbol counts | [references/ceilings-and-electrical.md](references/ceilings-and-electrical.md) |
| Specification cross-reference and revision control | [references/specifications.md](references/specifications.md) |
| Measurement records, calculations and net-only overlays | [references/geometry-and-delivery.md](references/geometry-and-delivery.md) |
| Demolition, salvage, protection, access cuts and linked restoration | [references/demolition-and-restoration.md](references/demolition-and-restoration.md) |
| Existing services, reuse/relocation register and infrastructure overlays | [references/infrastructure-reuse.md](references/infrastructure-reuse.md) |
| Doors, windows, storefront, shower glass and hardware sets | [references/openings-and-glazing.md](references/openings-and-glazing.md) |
| Membranes, substrates, flashing, sealants and assembly accessories | [references/waterproofing-and-accessories.md](references/waterproofing-and-accessories.md) |
| Treads, risers, landings, nosings, handrails, guards and metalwork | [references/stairs-and-railings.md](references/stairs-and-railings.md) |
| Earthwork, paving, drainage, fences, gates and landscape scope | [references/sitework.md](references/sitework.md) |
| Curved/irregular hardscape, site-wall segment audits and exhaustive demolition notation review | [references/irregular-sites-and-callout-audit.md](references/irregular-sites-and-callout-audit.md) |
| Prior-to-revised quantity, material, scope and correction reports | [references/revision-deltas.md](references/revision-deltas.md) |
| Cartons, bundles, sheets, stock lengths, rolls, slab yield and inventory | [references/material-ordering.md](references/material-ordering.md) |

## Required coordination records

Before measuring, cross-reference the applicable scope, architectural/structural/MEP sheets, designer pages, finish/selection schedules, specifications, addenda and recorded user decisions. Respect explicit review limits and procurement responsibilities. A newer date or a rendering does not by itself resolve conflicting documents.

Maintain these linked records alongside quantities:

- **Source register:** filename, revision/date, sheet/slide and actual file page, applicability, review status and missing references.
- **Callout coverage:** each relevant architectural and design callout, physical assembly/location, source references, scope responsibility, quantity IDs or explicit disposition, confidence and question IDs. A reviewed page alone does not establish complete coverage.
- **Question/conflict register:** stable ID, exact source evidence, affected quantity IDs, one answerable question, appropriate decision-maker, current estimating treatment and impact, status, and resolution record. Give the user wording they can answer or forward as an RFI; do not send it without authorization.

Measure supported work while keeping unresolved items visible. Unknown quantities are not zero or exclusions. When answers arrive, retain their source/date and update the manifest, workbook, scope notes and overlays together; do not silently leave superseded quantities or open questions in place.

For in-scope removal, relocation, penetration or assembly replacement, check related protection, access, service connections, substrate and finish restoration. Give each applicable operation a linked quantity or explicit unresolved/by-others/excluded disposition. Typical construction practice identifies questions; it does not authorize scope or establish missing quantities. Use the dedicated register fields in the relevant guides for infrastructure, openings, assemblies, revisions and ordering; keep those records in the outer project manifest without changing the area helper's schema.

## Establish the measurement basis

- For DXF or DWG, first read [references/cad-intake.md](references/cad-intake.md) and run the bundled capability check. Use native CAD geometry after verifying units, physical planes, insert transforms, dependencies and scope. DWG conversion is conditional on a working runtime converter; preserve the original and verify the derived DXF. Do not describe conversion success or a preview as proof of complete measurement. PDF-specific calibration below applies to PDF evidence and fallback plots, not directly to model coordinates.
- Read the actual source and revision. Inventory received pages against sheet indexes and printed pagination; identify missing schedules and referenced documents. Record filename, sheet number and PDF page index, finish legend, relevant keynotes, and requested trade/scope. Inspect drawings visually; text extraction locates information but does not define boundaries.
- Check for vector paths before tracing a raster. Normalize PDF rotation once without changing scale; preserve the coordinate transform. Verify a known landmark after placing or cropping a source page. With PyMuPDF, inspect `page.get_drawings()` and text boxes, and render detailed crops. Do not confuse window, furniture, dimension, overhead, or hatch lines with finished wall faces.
- Calibrate each sheet or differently scaled detail separately. Record original page dimensions, crop/rotation, units, labeled dimension endpoints, and the conversion to real units. In an unmodified PDF, 72 points = 1 inch; at 1/4 inch = 1 foot, nominal scale is 18 points/ft. That example is not a default for other projects.
- Compare independent horizontal and vertical dimensions where available. Match the dimension's actual witness points, which may reference framing/masonry rather than clear room width. Report discrepancies; investigate scanning, distortion, rotation, print fitting, or dimension rounding. Do not average incompatible checks to hide disagreement. Without defensible scale, provide a trace or provisional estimate and identify the missing basis.
- Mark included, excluded, and provisional scope on the plan. A cover-sheet remodel area is a comparison, not a target to which finish areas should be adjusted. A finish tag does not prove replacement scope.

For a requested completeness recheck, site-wall work, or irregular hardscape, read [references/irregular-sites-and-callout-audit.md](references/irregular-sites-and-callout-audit.md). Produce its occurrence register, wall ledger, and boundary evidence before claiming coverage. A broad trade-level TBD row does not close individually located work.

## Trace and classify

Work room by room or by connected finish zone. Use enlarged crops with coordinates when needed, then inspect the whole plan for continuity.

1. Trace interior finished faces for net flooring. Include angled bays, recesses, jogs and openings. Use the measurement basis appropriate to another requested planar finish; state it explicitly.
2. Allocate each shared doorway/threshold exactly once and record ownership. Resolve finish transitions explicitly. Clip exterior openings to the stated boundary. When revising an existing takeoff, preserve its scale and threshold-allocation conventions or quantify and explain the effect of changing them.
3. Give every quantity and geometry element a stable ID. Link the same physical item across plan and elevations; do not count it once per view. Separate plan area, elevation area, edge route and count evidence. Represent outer boundaries, thresholds, deductions, and addbacks explicitly. Describe what each shape represents and cite its source or assumption.
4. Read finish legend and keynote definitions directly. Mark inferred finishes rather than silently assigning adjacent finishes.
5. Keep gross, deductions, net installed area, waste, and order rounding separate. State when gross includes addbacks or an enclosed room that is then deducted and remeasured independently.

Use source dimensions when they establish the intended size, and retain traced geometry when that is the chosen basis. Record dimension-versus-scale conflicts and the selected basis; do not average them or silently replace a prior basis. A dimensional alternative is not an additional quantity. Exclude plain walls when requested; a finish tag alone does not turn an excluded wall into measured scope.

## Store and calculate once

Read [references/geometry-and-delivery.md](references/geometry-and-delivery.md) for the manifest, formulas, and deliverables.

For planar areas, create a polygon manifest for each independently calibrated measurement plane. Run:

```bash
python <skill-dir>/scripts/geometry.py manifest.json > measured.json
```

The bundled helper validates simple polygons, identifiers, signs and finite values, and calculates signed areas from vertices. **It does not validate relationships between polygons, agreement with the drawing, linear routes, symbol counts, or slab fabrication.** Use the separate record/formula guidance for LF, EA and dimensional quantities; do not feed them to this area-only helper. Read its `validation.not_checked` output and complete those checks separately. Its tests can be run with `python <skill-dir>/scripts/test_geometry.py`.

Generate overlay paths directly from those same stored vertices. Fill only the Boolean net surface; leave openings and other-material deductions unfilled. Retain gross and deduction geometry for audit. Mark locator-only graphics explicitly and never calculate their displayed area as the quantity. Generate spreadsheet calculations from the vertices or link them to the authoritative geometry table; do not separately type quantities into the schedule. Preserve full precision internally and round the displayed results sensibly. Label assumptions and editable inputs.

Use the available PDF and spreadsheet skills for format-specific creation, recalculation and rendering. Do not substitute image generation for precise measurement geometry. Persist completed user deliverables through the environment's supported artifact workflow; skill installation itself is separate.

## Verify before delivery

- **Measurement effort:** Separate genuinely missing design information from work that is depicted but has not yet been traced or counted. Complete the latter; if it remains unfinished, report it as incomplete measurement, not an RFI or source limitation. Check boundary fidelity and callout completeness independently of arithmetic.
- **Visual correspondence:** Render the final overlay and inspect every included zone, all deductions, door transitions and scope cuts at useful detail. Compare to the unmarked source. Fix boundaries crossing walls or claiming adjacent rooms. Use readable IDs and transparent fills without obscuring the evidence.
- **Topology:** Within each physical measurement plane and scope, test containment and overlap using polygon Boolean operations if available. Inspect gaps against the source; a no-overlap result does not prove complete coverage. Do not treat a top and its elevation face, repeated locator, or alternate basis as coplanar overlap. Otherwise independently rasterize at declared resolution with consistent pixel-center rules, inspect intersections/gaps, and quantify boundary discretization. For signed masks, valid net occupancy is 0 or 1: overlap values above 1 and negative regions require investigation. Shared edges alone are not area overlap. Do not silently clip bad deductions or raise tolerances to obtain a pass. Explicit addbacks must restore part of a deducted region, not duplicate open floor.
- **Arithmetic:** Compare independent area calculations or raster estimates to the analytic polygon areas. For simple rooms also compare width × length, allowing for jogs/deductions. Reconcile each zone and finish subtotal to the detailed geometry. A numeric match alone does not validate topology.
- **Artifact fidelity:** Recalculate and inspect the exported workbook for errors and matching cached values; render the important sheets. Verify that changing an input updates dependent formulas. Vertex edits require regenerating the PDF—an exported overlay is a snapshot, not live-linked Excel geometry.
- **Cross-reference closure:** Every applicable callout must link to a quantity or an explicit retained/excluded/by-others/option/unquantified disposition. Link every unresolved dependency to a question ID and present the material questions to the user. Verify both directions: source callouts to quantity rows and quantity rows back to evidence.
- **Legend correspondence:** Check every drawn mark against its page legend for exact ID, color/style, description, quantity and unit. Map individual routes and count suffixes explicitly to parent subtotals; identify reference-only quantities without marks.
- **Scope:** Reconcile the room-by-trade coverage list; keep partial electrical evidence, retained ceiling LF and incomplete specifications explicit. Separate fabrication classes and informational subtotals so totals cannot double-count the same work. List exclusions, unresolved dimensions/finish selections and assumption-sensitive quantities. Do not describe a provisional partial zone as whole-project or purchase-ready. Do not force a match with architectural gross area.
- **Related work and procurement:** Reconcile parent assemblies with documented components and access/restoration operations; distinguish physical counts from operation counts. Verify reuse status and uncertainty labels against evidence. Check order estimates against actual product/stock constraints, allocated inventory, separate spares and rounding; keep installed quantities unchanged.
- **Revisions:** Preserve prior snapshots, verify comparable bases and stable identity, and report numeric and nonnumeric changes. Unknown-to-known quantities and missing excerpt items are not automatic additions/deletions. Reconcile changed and unaffected rows through all paired deliverables.

Deliver a marked plan with overview and useful detail views, a quantity workbook with gross/deductions/net and formulas, and concise measurement-basis notes. Put the reproducible geometry in the workbook or a companion manifest. Adapt deliverables to the user's request; for a requested trace or calculation only, do not create unrequested packages. Explain what was measured, what checks actually ran, and material unresolved items.
