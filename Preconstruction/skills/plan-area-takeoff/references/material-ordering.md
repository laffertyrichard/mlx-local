# Material ordering calculations

Use when order quantities are requested and product/package information is available. Separate net installed quantity, layout/cut requirement, explicit lap allowance, waste, spare stock, usable allocated inventory, package rounding and new purchase quantity. An installed takeoff is not automatically a fabrication or purchase schedule.

## Required procurement fields

Record quantity IDs, exact product/SKU and relevant finish/size/thickness/lot constraints, installed unit, package unit and coverage/yield source, layout basis, allowance values and what they include, spare requirement, usable allocated stock, known orders/status, rounding rule, calculated demand, new purchase quantity and unresolved questions. Inventory must be compatible, usable and allocated once; unconfirmed stock is not a deduction.

Aggregate compatible demand before package rounding when material can be shared. Keep separate SKUs, lots, delivery phases or nonshareable allocations distinct. State whether a waste percentage includes cuts, breakage or laps to avoid adding them twice. Missing product or layout data produces an estimate or held quantity, not a purchase-ready label.

## Packaged area goods

For a documented percentage-waste basis, demand = net installed × (1 + waste) + separately specified spare quantity in the same units. New packages = ceil(max(0, demand - usable allocated stock) / coverage per package). Record the resulting excess from package rounding separately. If spares must be unopened full packages, preserve that requirement and calculate those packages separately; do not satisfy them with projected offcuts.

Example: 125 SF net, approved 10% waste, 12 SF/carton and 2 usable allocated cartons requires ceil((137.5 - 24) / 12) = 10 installation cartons to purchase. One additional unopened spare carton gives 11 new cartons total. Installed SF stays 125; spare stock and carton rounding do not become installed quantity.

## Product-specific constraints

| Product | Required method / ordering limit |
|---|---|
| Tile / plank / bundles | Actual carton coverage and layout/pattern basis; width/direction, modular borders and mixed sizes may require piece counts |
| Sheet goods | Layer-specific surfaces, sheet size/orientation, support and joint rules, cut plan and usable offcuts; area division is only a lower bound |
| Stock lengths | Piece/cut list, available lengths, continuity/joint rules, kerf and reusable offcuts; total LF division is only a lower bound |
| Carpet / sheet rolls | Roll width, direction, repeat/matching, permitted seams and strip layout; floor SF divided by width alone is insufficient |
| Slab stone | Actual usable slab sizes, defects, vein direction, seams/bookmatching and fabrication nesting; finished SF plus percentage waste does not establish slab count |
| Membranes / coatings / sealants | Stated product yield, coats, laps and joint sections as applicable; use the assembly accessories procedure |

For stock cuts, allocate each required continuous piece to a feasible stock piece. Two 8-ft lengths cannot supply one required continuous 13-ft piece. Report the mismatch and request a suitable stock length or approved joint/design change; do not turn sufficient aggregate LF into a compliant order.

Label carton calculations based on an approved percentage as procurement estimates where layout is unresolved. Label sheet/roll/slab quantities as purchase-ready only when the applicable layout and product constraints are established. Confirm whether vendor fabrication or field dimensions remain outstanding. Provide proposed order quantities for review; calculating them does not authorize placing orders, returns or cancellations.
