# Irregular site geometry and complete callout audits

## Deliverable contract

For irregular exterior work or a completeness recheck, produce three linked records before a quantity summary:

1. **Notation occurrences:** one physical leader target per record, not one row per keynote definition.
2. **Wall segments:** every visible in-scope run split at work-status, section, elevation and junction changes.
3. **Surface boundaries:** separate connected finish zones with exact vector edge references or high-resolution trace evidence, curve treatment, deductions and surface ownership.

Label evidence unavailable separately from measurement unfinished. Missing height can hold wall SF/CY while its depicted LF is measurable. Missing trench depth does not prevent counting a located access operation. A catch-all row such as “remaining demolition TBD” is a scope reminder, not completed coverage.

## Enumerate demolition and related instructions

- Read the legend and every keynote definition directly. Inspect the full plan in overlapping tiles at a scale where leaders and digits are legible. Cover inset plans as well as the main drawing; retain a tile/review map.
- Assign every occurrence an ID, note code or literal text, sheet/PDF page, leader target coordinate, physical item ID, operation, quantity ID, disposition, confidence and outstanding question. Keep ambiguous digits visibly ambiguous until the leader and nearby context resolve them.
- Search other relevant sheets for REMOVE, DEMO, SAWCUT, CUT, TRIM, LOWER, RAISE, RELOCATE, REPLACE, INFILL, CAP, SHORE, SALVAGE and REMAIN; also inspect these graphically because outlined/raster text can defeat extraction. Use OCR to locate candidates when native extraction fails, then confirm the wording and leaders graphically.
- Distinguish removal, partial lowering, retained protection, relocation, new-over-existing and temporary support. “To remain” is a recorded disposition. Repeated leaders can point to one physical item: preserve all occurrences but count the item once. A bubble branching to three targets creates three occurrence rows; a repeated roof or detail view creates evidence, not extra units. Distinguish a schedule-row locator from a field-target coordinate.
- For each defined code, state occurrence count and locations or explicitly “legend only; no occurrence found after tiled review.” Reconcile all free-text notations too. An unquantified located item still needs its own row and a concrete reason, not a generic trade-level omission.
- Trace depicted removal limits independently of proposed geometry. Do not use new paving area as demolished paving area. Split stairs, walls, cabinets, roof support and service disconnection/restoration into their actual operations and units. An opening dimension spanning a doorway is not net solid-wall demolition LF.

## Site-wall ledger

Create one row per physical segment with start/end locators, traced centerline or face basis, LF, wall type/thickness, status (new, retained, demolished, lowered, raised/on existing, unresolved), top/bottom/footing elevations, source section, parent system and quantity IDs. Retain distinct parallel walls in double-wall/planter systems; deduplicate coincident edges of one wall. Trace short returns, cross walls, curved ends, gate jambs, planter enclosures, equipment screening and trash enclosures as well as long outside runs.

Cross-reference demolition, hardscape, foundation, civil and elevations. A sheet-wide schedule is a check, not a substitute for the segment ledger. Explain differences in scope or basis instead of scaling segments to force its total. An unknown height or section holds only dependent SF, concrete, grout and reinforcing quantities; it does not erase supported LF. Keep caps, stucco/paint faces, waterproofing/drains and footing routes linked but separate from wall length. For stepped or sloping heights, use interval end elevations or a sourced section; never apply one height to the whole site.

## Curved/irregular surface measurement

1. Normalize PDF rotation and establish the coordinate frame before extracting geometry. Retain original rotation/media box, normalized frame and the forward/inverse transform. Record PDF-point-to-render transform and two independent dimension checks. Test a known corner and a distant landmark after placing the page in the final output.
2. Inspect native drawing paths before raster tracing. Extract actual boundary lines/arcs/Bezier segments when identifiable; filter text, hatch, furniture, overhead lines and offset wall faces. CAD strokes may be exported as filled thin polygons: inspecting only stroke-type paths can falsely suggest usable vector geometry is absent. A vector PDF can still contain raster detail views; assess each relevant viewport.
3. Preserve exact line/curve definitions and ordered segment IDs in the measurement record. Tessellate curves adaptively with a declared maximum chord error tied to source line width/precision. Verify length and area convergence at half the chord tolerance; do not use vertex count as a quality claim. Numerical convergence checks curve sampling only; it does not prove correct boundary choice, scale or finish ownership. Record the tolerance and observed change.
4. When boundaries cannot be reliably recovered as vectors, use enlarged, overlapping crops and enough control points to follow each arc, fillet and concave transition. Record source resolution, boundary convention and uncertainty. A thumbnail traced with a few long straight chords is not an adequate curved-surface takeoff.
5. Split stair treads/landings, raised platforms, ramps, coping, columns, built-in firepits and landscaping into independent surfaces/holes. Define ownership along pool/spa and planter edges. Furniture is not an automatic floor deduction. Do not silently clip deductions to make invalid geometry pass; investigate and correct their source boundary. If a fixed object truly straddles a finish-zone edge, record full object area, in-zone overlap and the physical reason; do not hide partial overlaps.
6. Inspect all perimeter segments and every hole at useful detail, not just the full-sheet overview. Use numbered boundary segments and crop coverage to prove this review. Show rejected and unresolved intervals explicitly if source evidence prevents closure.
7. Check independent area arithmetic, Boolean containment/overlap, curve convergence and source correspondence separately. A matching shoelace sum and overlay generated from the same wrong vertices cannot validate the interpretation. State which of these checks actually ran.

## Revision and acceptance

Preserve the earlier snapshot. Report comparable geometry corrections separately from newly measured work and changed scope or boundary conventions. A switch from all horizontal surfaces to hatched finish fields is a basis change, not pure tracing error. Map split/merged IDs, show gross/deduction/net changes, and update workbook formulas, marked plans and questions together. Repeated detail plates are reference views, not additional quantity.

Accept a completeness claim only when every notation occurrence and boundary interval has a disposition and all depicted measurable work has been attempted and each remaining interval is specifically identified. A notation audit alone does not establish quantity completeness. Accept a curved-area quantity only after the detailed edge inspection and convergence/independent checks above. Do not call PDF-derived work perfect or fabrication-ready; disclose actual uncertainty without using “provisional” to excuse preventable coarse tracing or omitted work.
