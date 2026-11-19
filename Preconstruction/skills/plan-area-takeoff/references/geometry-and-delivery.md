# Geometry and deliverables

## Planar manifest

Use one manifest per sheet/calibration plane. `scale` is coordinate units per real-world length unit, so areas divide by `scale²`. Include units explicitly in metadata and all deliverables. PDF points and raster pixels are different coordinate systems; retain any transformation needed to map crops back to original source coordinates. For an anisotropically distorted scan, correct the image/coordinates with defensible calibration or use a documented affine area transform outside this uniform-scale helper.

Minimal executable example (coordinates in PDF points, lengths in feet):

```json
{
  "source": {"file": "plan.pdf", "sheet": "A2", "page_index": 0, "revision": "record from source"},
  "coordinate_system": "PDF points; top-left origin; x right; y down; original unrotated page",
  "length_unit": "ft",
  "area_unit": "SF",
  "scale": 18,
  "scale_note": "Record dimension checks and chosen basis here",
  "scope": "Explicit included zone and exclusions",
  "zones": [{"id": "W01", "name": "Room", "finish": "Wood", "note": "Installation basis"}],
  "polys": [
    {"id": "G01", "zone": "W01", "sign": 1, "pts": [[100,100],[316,100],[316,280],[100,280]], "note": "Inside finished walls"},
    {"id": "D01", "zone": "W01", "sign": -1, "pts": [[154,154],[190,154],[190,208],[154,208]], "note": "Fixed island base, flooring excluded"}
  ]
}
```

This analytic example is 120 SF gross minus 6 SF = 114 SF net; it is not a project's calibration. Use ordered vertices, either orientation, without repeating the first vertex at the end. Every sign is +1 or -1. The helper tolerates additional metadata and overwrites derived quantities on recalculation. Units are declared by the author, not inferred by the helper.

Represent holes as negative polygons and doorway additions as positive polygons. Preserve intentional parent-child relationships in metadata. Multiple gross regions, overlapping deductions and addbacks require Boolean or signed-occupancy checks: summing individual shoelace areas cannot establish valid set geometry. For an addback inside a deduction, evaluate signed occupancy or explicitly restore the valid addback mask; a simple union-of-gross minus union-of-deductions would remove that addback again.

## Additional measurement records

Keep the area helper's input schema unchanged. For multi-trade work, use an outer project manifest containing sources, calibration planes, quantity rows and review issues. Store or reference separate area-helper manifests for planar calculations; the outer manifest is not itself executable by `geometry.py`.

Assign each source/calibration frame a unique `source_id`, including render dimensions, rotation and crop transform. Attach it to every geometry record. The same PDF page rendered at different sizes produces different frames; page index alone is not a safe merge key. Validate every mark against its own frame bounds.

Each quantity row should establish:

- Stable ID, room/location, trade, finish and fabrication/category group.
- Unit (SF, LF, EA or CY), selected basis, source page/detail and confidence/status.
- Geometry references and physical plane; positive/deduction role for areas.
- Dimensional inputs with units and formula when dimensions govern; point locators/evidence for counts.
- Scope class (new, retained, excluded, provisional, option or unresolved), measured reference quantity and inclusion in each total.
- Parent/subset or alternative relationship and physical layer/assembly where quantities share a footprint.
- Product/specification references and affected review IDs when supplied.
- Physical item ID separate from operation ID for removal/reinstallation, plus responsibility, related-work IDs and decision/verification evidence where applicable.

Keep infrastructure, opening, assembly-component, revision and procurement records in this outer manifest using the required fields in their routed references. Link them to quantity and source IDs; do not feed procurement counts or revision deltas to the planar area helper. Preserve unknown values as null/unresolved through exports instead of converting them to numeric zero.

Allow these distinct geometry roles: area polygon, measured polyline, count point, and locator only. A locator can show where a spec-dimensional quantity belongs; it is never an area/length input. Two physical surfaces can share a locator without double-counting. Store explicit relationships for alternatives and informational subtotals so they cannot be added to their component quantities.

Calculate measured LF as the sum of segment lengths divided by that detail's scale; close the line only for an intended perimeter. Calculate EA from the deduplicated physical-item list, not the number of appearances across views. For dimensions in inches, LF = length / 12 and SF = width x height / 144. Use a face's actual measurement plane, not its foreshortened appearance in an unrelated view.

## Spreadsheet

Useful sheets:

- **Summary:** Room/trade quantities and finish totals; gross/deductions/net for areas, separate LF and EA, scope notes and optional editable waste. Split horizontal tops, slab backsplashes, bench/ledge tops, aprons/returns and edge bands for fabrication pricing. Do not combine unlike materials into an order quantity.
- **Geometry:** Polygon ID, owning zone, sign, area, signed area, vertex range, source and interpretation.
- **Vertices:** Polygon ID, sequence, x, y, next x/y and cross product. Link next-coordinate cells to the subsequent vertex row, closing the last row to the first; duplicated static next-coordinate inputs become stale when a vertex changes.
- **Basis / Notes:** Scale inputs and evidence, source/revision, units, exclusions and open decisions.
- **Applicable scope registers:** Infrastructure, openings, related-work/assembly components, revision deltas and material orders when requested or needed for the included scope. Generate these from the same linked manifest records; keep retained references, operations and new procurement in distinct totals.

For vertices `(x_i,y_i)`, area = `ABS(SUM(x_i*y_next - x_next*y_i))/2/scale^2`. Geometry must link to scale; zone quantities must link to Geometry. Net = gross - deductions. Waste belongs in a separate editable input, not the geometry. Do not imply one tile subtotal is one SKU, or that area waste alone handles carpet roll layout or pack rounding.

Keep category fields inside sortable table ranges so sorting cannot detach a category from its quantity. Validate every computed line against the selected measurement basis; check meaningful editable dimensions such as niche depth and edge height. Keep retained quantities out of new-install totals and label unknown values as unresolved, not numeric zero.

Use readable numerical precision (often 0.1 SF); retain exact coordinates internally. A one-decimal display is not a claim of field accuracy. A changed workbook scale or vertex does not automatically update the delivered PDF: regenerate and reverify the paired outputs.

## Overlay

Preserve the original source as a vector page where possible. Draw the manifest's coordinates in its original coordinate frame before cropping/resizing views. Use subdued finish colors, stable IDs and a legible legend containing quantity and unit. Repeat references across views without adding their quantities. For derived surfaces, show the resulting SF alongside its supporting route/projection ID. Compute Boolean net polygons from the same gross/deduction records, and fill only the net surface with holes preserved. Do not tint the gross shape and then tint its deductions: excluded glass doors, slab benches or voids must remain unfilled. Outline deductions with a distinct dashed line and label exclusions where interpretation is easy to confuse. Distinguish retained/excluded reference scope visually from new work. Separately measured finishes may fill their own polygons; do not paint another scope's negative mask over them. Separate trade views when shared geometry would obscure meaning. Show polylines for LF and distinct count marks for EA. Label locator-only graphics; leave them unfilled or use a clearly different locator style. Add useful enlarged views for wet rooms, islands, floating slab faces and narrow transitions.

Build marks and legends from the same records, including display ID, color/style, description, quantity and unit. Verify both directions on every exported page: each mark has a matching legend entry and each legend entry identifies its marks or is explicitly labeled a related/reference quantity with no additional mark. Enumerate individual routes and count suffixes, or state their exact range and parent mapping. Do not show only a parent subtotal when the drawing uses unrelated child IDs. Keep measured route LF distinct from derived wall SF or concrete CY even when they share geometry. Split crowded views rather than clipping labels or dropping entries.

Close each rendered ring independently and preserve holes. If triangulating or partitioning the fill, clip pieces to the net geometry and retain every nonempty polygon component; do not discard boundary-crossing pieces merely because their centroid or whole shape fails a containment test. Verify that the union of rendered fill pieces matches the Boolean net mask, checking both missing and extra area. Correct quantity arithmetic alone does not establish a correct overlay.

Show provisional scope divisions with distinct dashed boundaries and a label. Label any fitted or enlarged view "Do not scale this view" unless a new verified plotted scale is supplied. Do not leave the original scale label as the only guidance on a resized sheet.

Include comparison to a stated remodel/building area only with its measurement basis. Net finish, gross floor area, selective replacement and whole-building area are not interchangeable. An unexplained difference remains an open scope item rather than a correction factor.

Render the final export, not only a scratch overlay. Inspect every new or revised zone, excluded opening, corner and count group against the source at useful detail. Size legends/footers for the actual row count; do not let added rooms overflow them. Enlargements must preserve the crop transform and avoid clipping callouts or including confusing fragments of neighboring details. A revision to coordinates, scale or dimensional inputs requires regenerating the paired snapshot overlays.
