# Revision quantity reports

Use for revised drawings, selections, scope decisions or corrections to an issued takeoff. Preserve immutable prior and revised manifest snapshots with source revisions, hashes where available, and dated/timestamped deliverable names. Compare the selected basis in each; do not silently compare an option to an accepted baseline.

## Required delta rows

Record stable physical/quantity ID, room/trade, old/new source and manifest versions, old/new scope status, material/specification, unit, quantity, numeric delta or reason unavailable, change class, cause/evidence, affected linked IDs, question/decision ID and procurement implication when known.

Classify added, removed, quantity changed, material/assembly changed, relocated, newly established, measurement correction, display-only correction, unchanged or unresolved. Multiple classifications may apply. A zero numeric delta can still change scope or cost.

1. Match stable IDs and physical identity first. Where IDs split or merge, record old-to-new mappings; do not interpret ID churn as new construction. Never match by room name alone.
2. Confirm units, physical layers, inclusion rules, measurement basis and review boundaries are comparable. Convert known compatible units explicitly. Keep unresolved or incompatible comparisons out of numeric totals.
3. Compute delta = new - old only for established comparable quantities. A confirmed added item can have an explicit old zero; a confirmed deletion can have an explicit new zero. Unknown is never converted to zero.
4. Treat an item absent from a partial revised excerpt as unresolved, not deleted. Retain the prior value as reference while identifying what revision evidence is needed.
5. Report calibration, geometry interpretation and deduction-policy corrections separately from design/scope changes. A corrected overlay with unchanged source quantities is display-only.
6. Recheck dependencies: moved fixtures affect access/restoration; bench dimensions affect floor/wall fields; opening changes affect substrate/finish quantities; selections affect product subtotals and orders.

Example: 100 SF of tile A replaced by 100 SF of tile B has zero installed-area change, with -100 SF in A and +100 SF in B material groups. An unknown quantity becoming 40 SF is newly established, not a demonstrated +40 SF increase. A previous 30 SF item missing from an excerpt has no established deletion delta.

## Reconciliation and delivery

Reconcile old total + numeric deltas = new total only within a complete comparable group. Show newly established/unresolved contributions separately so an incomplete comparison cannot masquerade as a balanced change report. Recompute aggregate totals from manifest rows, excluding informational subsets and alternatives.

Show product, responsibility, location and assembly changes even where net totals cancel. Distinguish installed-quantity deltas from revised procurement demand. Allocated stock, already ordered goods, cancellation/return status and waste assumptions prevent a material delta from directly becoming a purchase or credit instruction.

Include a concise change summary and detailed workbook delta table; mark changes on overlays when useful without disturbing their source frames. Update quantities, questions, scope notes and legends together, verify unaffected IDs remain unchanged, and retain the superseded snapshots for audit. Never overwrite the only copy of an issued baseline.
