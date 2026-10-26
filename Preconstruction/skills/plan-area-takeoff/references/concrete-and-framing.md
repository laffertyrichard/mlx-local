# Concrete, masonry and framing takeoffs

Measure depicted construction; do not design missing structural assemblies. Read actual foundation, framing, shear and detail sheets, schedules and referenced calculations. Actual sheet titles govern over stale indexes. Separate new work, retained construction, retrofit, demolition, alternatives and unresolved scope. A finish-area helper does not validate structure or volumes.

## Foundation and slab ledger

Build a location-by-assembly ledger: continuous footing type/centerline LF, isolated pads EA and dimensions, slab polygons/thickness, retained slab topping, thickened edges/haunches, stems/curbs, depressed slabs and interfaces. Link each plan tag to its actual detail. Record which dimensions are minimum embedment versus complete geometry.

- For every continuous footing run/type, report **both LF and CY** as separate quantities in the schedule and overlay legend. Label the LF item with its structural footing size, explicitly **width × concrete thickness/depth**, plus footing tag, location and sheet/detail reference. Example: `CF-1 continuous footing, 16 in W × 10 in thick, west wall, detail 4/S-1 — 30 LF`; the linked gross volume is `30 × (16/12) × (10/12) / 27 = 1.23 CY`. These describe the same footing, not additional scope.
- Split runs wherever the footing size or section detail changes; retain LF and CY subtotals by size/type. Calculate CY from the same stored LF and sourced section dimensions, with intersection deductions and waste shown separately. Preserve the full route LF when shared concrete reduces net CY. Carry the size/type labels through the workbook and marked-plan legend.
- If the detail leaves a section dimension unresolved or conflicts with the schedule, report the supported LF with the known size and an explicit unresolved dimension. Keep CY provisional or unestablished; do not substitute embedment depth for concrete thickness or silently assume a rectangular section.
- Calculate volume in CY as SF × thickness in feet / 27, or LF × section area in square feet / 27. Keep each section component separate. A rectangular below-grade component is not total foundation concrete when stems, tapers or haunches remain unknown. Do not infer an excavation section from concrete volume.
- Allocate shared concrete once in three dimensions. Split footing/pad intersections by footprint AND elevation/depth; deduct only their common volume. Keep the continuous centerline LF ledger independent from net concrete volume. Show gross pad envelopes as nonadditive references when a selected net combined volume already includes them. A split-pad interpretation is an alternative to its full envelope, not another pad.
- Trace new slab, retained slab and topping separately. Existing footprint does not establish topping scope or thickness. Keep a defensible retained-slab core and unknown perimeter bands distinct. Check that new slabs and topping do not overlap in the same physical layer.
- Calculate base/compacted fill from its own net field and specified thickness. Deduct footprint occupied by footings/other assemblies where applicable. Alternative specified base materials are alternatives, not additive layers.
- Record mesh by installed area before laps; determine separately whether topping receives it. Keep waterproofing/vapor barrier, joints, dowels and demolition unknown until scope and dimensions are established.
- Reinforcement records require bar size, count/spacing, layer, direction, shape and detail source. Continuous bar LF = route LF × number of longitudinal bars; a straight-length baseline excludes laps, hooks, development and bends unless explicitly added. For spaced bars, state first/last placement, edge cover and rounding. Do not call an envelope-based bar allowance a bending schedule. Do not deduct bar length merely because concrete overlaps another foundation component.

## Framing and structural hardware

Trace wall runs by framing type, new/retained status and location. Keep exterior/interior, load-bearing/nonbearing, shear-retrofit and special stud spacing distinct. Untagged sizes or spacings remain editable assumptions.

- Wall LF follows a stated framing face or centerline. Record opening widths, corners, intersections and end ownership. Plate LF = selected run × documented plate courses; treatment through openings must be stated. Stock length, laps and waste are separate.
- Baseline stud counts may use ceil(run/spacing) + 1 per independent run, adjusted for explicitly shared ends and known openings. Label this a spacing allowance: it does not establish king/jack/cripple studs, corners, intersections or blocking. Do not silently convert it into a complete lumber order.
- List headers by opening ID, size, ply count, bearing and length basis. Header lumber LF includes plies; distinguish clear opening length from overall cut length including known bearing. Missing bearing is unresolved, not a standard default.
- Count uniquely tagged girders/hip trusses and trace their plan spans where shown. A truss span is not chord/web lumber. Ordinary/jack trusses and deferred designs require their own schedule; do not infer complete fabrication quantities from a few tagged members.
- Keep shear-line LF separate from new wall framing LF. Retrofit may occur on retained walls. Count holdowns, straps, anchors and connectors by distinct depicted location, linked to hardware type/detail. Spacing-based anchor counts are allowances with end-distance and segment assumptions. Calculate prescribed fasteners from assemblies × specified fasteners per assembly; detail availability alone does not establish occurrence counts.
- Wall sheathing SF = route × sourced height, less documented openings; gables/upper infill are separate shapes. Roof sheathing uses actual structural boundary and each plane's slope. Cross-reference roofing geometry without forcing the areas to agree.

## Masonry and demolition

Quantify masonry only where new/removed limits, heights, thickness and opening deductions are established. Separate wall SF, unit count basis, bond beams, lintels, grouted cells and reinforcing. Do not infer grout volume or structural unit count from gross wall area without assembly data. No depicted new masonry means extent not established, not zero scope.

Use demolition plans and scope statements to establish removal limits; an existing/proposed visual difference alone is not a structural demolition takeoff. Keep already-completed demolition excluded and potential retained-wall retrofit separate. Deliver unresolved quantities explicitly rather than labeling a partial structural schedule purchase-ready.
