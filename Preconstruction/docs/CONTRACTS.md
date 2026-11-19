# Domain contracts and invariants

The proposal schema in `schemas/revision.schema.json` is for a new versioned revision envelope. Keep `templates/project/measurements/project-manifest.json` and the area-helper plane schema intact until an explicit migration is implemented. Fixtures demonstrate the proposed envelope; they are not evidence of an installed application feature.

## Sources, calibration and geometry

Each source has a stable ID, content SHA-256, immutable relative path, revision, page/sheet identity and source role (existing/proposed/record/specification/decision). Same filename with changed bytes is a new retained source. Derivations record their parent hash, exact affine transform, output dimensions, crop/rotation and processing version. Source path, frame ID and physical plane are different concepts.

Calibration records length units, coordinate units, conversion, dimension endpoints/witness datum and independent X/Y checks. Contradictory checks yield `conflict`, not a mean scale. A written dimensional basis can calculate a quantity without claiming a traced polygon is correct. Anisotropic scans require a defensible explicit correction/affine area calculation, not uniform-helper misuse. Declared physical plane separates plan flooring, elevation tile, tops/returns, alternatives and repeated locators.

Geometry has one of four roles: area polygon, measured polyline, count point, locator only. Locators are never numeric area/length inputs. Areas derive from signed vertices plus scale; holes/addbacks need topology validation. LF closes only for a stated perimeter. EA deduplicates physical item IDs across repeated views. Include evidence records and units for all formula inputs. Installed quantity, waste, spares, stock yield and order rounding are separate records and totals.

## Scope and uncertainty

Rows retain stable quantity ID, physical-item ID, operation, room/trade/material, unit, selected basis, evidence IDs, geometry IDs, confidence/basis, state, responsibility and related work. Existing/retained, demolition, relocation and new/proposed quantities cannot be netted indiscriminately. Alternatives and informational subtotals have explicit relationships and are never summed with the selected components.

A null value means unestablished. Zero is allowed only with affirmative cited evidence and a declared zero basis. Provisional values remain labeled and segregated from released totals. Missing depicted measurement goes to the unfinished-measurement register; missing design/selection/conflicting source goes to the question register. An excluded or by-others disposition needs an explicit scope basis, not lack of a measured number. Scope can change without a numeric delta; unknown-to-known is not automatically a new addition.

Every applicable callout maps to a quantity or a sourced disposition. Every quantity/claim maps back to evidence. Claim mapping must include generated client wording, internal wording, assumptions, exclusions and material open issues. A sentence containing an unsupported material, operation or quantity fails even if it reads plausibly. Client/internal separation must not hide material uncertainty from the client.

## Revisions and approvals

An approval binds snapshot digest, actor/date, decision scope and approved IDs. `reviewed_geometry`, `scope_release`, `design`, `field`, `fabrication`, `procurement`, `engineering` and `code_basis_review` are distinct gates. Code basis review is never compliance certification. A source or calibration change invalidates affected dependent quantities, artifacts and approvals; preserve the prior package and stable identities. Record authority and resolution scope by decision, not a universal newest-file rule.

Block scope release when relevant unknowns, conflicts or failed/unavailable required checks remain unless the human explicitly approves a clearly bounded provisional issue that discloses them. Never convert the provisional release to fabrication/procurement readiness. Draft RFIs stay local until separately authorized.

## Code research

A binding requirement claim requires verified parcel/building/zoning/fire jurisdiction as applicable, adopted code path/edition, enactment and local amendment/appendix/effective-date evidence, permit-date basis, exact section/table/exception, project applicability reasoning, project evidence and retrieval date. Separate recommendations, design judgment and assumptions. An imported code PDF, “residential” label, official URL or owner approval alone is insufficient. Offline/unverified jurisdiction remains unresolved. No automated result guarantees compliance or engineering safety.

## Scope export

Default scope only: no markup, pricing or trade-pricing lookup. Include quantities/units and selected basis, inclusions, supported exclusions, responsibility, linked access/protection/restoration and open decisions. Keep vendor costs only in internal notes when actually supplied. Proposal plain text uses hyphens, blank lines, explicit units, no markdown/smart punctuation, and at most 4000 characters per line item. Split at semantic boundaries and retain stable IDs if longer. Generic CSI/exclusion lists are legacy reference prompts, never current universal standards or default project exclusions.
