---
name: buildertrend-proposal
description: >
  Format construction proposal line items and internal notes for Buildertrend import.
  Use when the user explicitly asks to format for Buildertrend, create Buildertrend line items,
  generate client-facing proposal text, or produce internal field notes from vendor bids.
  Triggers on phrases like "format for Buildertrend", "create line item", "proposal line item",
  "client-facing scope", "internal notes for [trade]", or "Buildertrend format".
  Do NOT trigger on general bid analysis, cost comparison, or estimating tasks unless
  the user specifically requests Buildertrend-formatted output.
---

# Buildertrend Proposal Formatting

Format construction vendor bids into client-facing Buildertrend line items and companion internal field notes.

## Core Workflow

For each trade bid:

1. Extract complete scope, inclusions, and exclusions from the vendor bid
2. Identify scope gaps by comparing bid to plans
3. Only when pricing is explicitly requested, apply established project-specific markup; otherwise omit prices and retain quantity/scope status
4. Produce two outputs: **client-facing line item** + **internal notes**

Always produce both outputs unless the user requests only one.

## Buildertrend Formatting Rules

These rules are strict — Buildertrend does not render markdown or special characters.

| Rule | Detail |
|------|--------|
| Max characters | 4,000 per line item — check count before finalizing |
| Bullet style | Hyphens only (`-`). NEVER asterisks, bullets, or numbered lists |
| Spacing | One blank line between each scope item |
| Bold/italic | NONE — Buildertrend ignores markdown formatting |
| Special chars | Plain text only — no em dashes, smart quotes, or unicode |
| Measurements | Include units: SF, LF, EA, CY, approx., Qty |

### Client-Facing Line Item Template

```
[Trade Name]
[CSI Code] - [CSI Description]

[Opening scope summary — 1-2 sentences referencing plans date]

-First scope item with measurements

-Second scope item with specifications

-Third scope item

[Room/area breakdowns if applicable]

-Exclusion 1

-Exclusion 2

NOTE: [Important clarifications or allowance notes]

[Trade Name] Total: $[Amount]
```

### Internal Notes Template

```
INTERNAL NOTES - [TRADE NAME] ([CSI CODE])

[Vendor Name]

Bid Date: [MM/DD/YYYY]

Expires: [MM/DD/YYYY]

[Category 1]:

-Item description with cost: $X,XXX

-Item description with cost: $X,XXX

[Category 2]:

-Item description with cost: $X,XXX

Exclusions:

-Exclusion requiring field coordination

-Exclusion requiring field coordination
```

Internal notes guidelines:
- Keep vendor costs visible for field reference
- Organize by logical categories (Equipment, Materials, Labor, etc.)
- Only include exclusions that require field coordination
- Remove warranty details, payment terms, technical specs
- Keep it scannable — essential information only

## Markup Application

Markups are project-specific. If not already established, ask the user for their markup structure before calculating client pricing. Common categories:

- Materials (purchased direct)
- Subcontractor labor
- Windows & doors
- Fixtures & finishes
- Allowances

Calculation: Vendor bid x markup multiplier = client price.
Example: $10,000 sub labor x 1.70 = $17,000 client price.

## Allowance Format

Use when selections are not yet finalized or scope is variable:

```
[Item] Allowance
[CSI Code]

[Description of what allowance covers]

-Specific inclusions

-What is NOT included

NOTE: Client may invest more or less as desired. [Context]

Allowance Total: $[Amount]
```

For owner-direct purchases, state "Owner furnished; pricing not included". Omit price unless an explicit sourced platform convention requires $0.00; unknown price or quantity must never become zero.

## Reference Files

Load these as needed based on the trade being formatted:

- **[references/csi-codes.md](references/csi-codes.md)** — Standard trade sequence with CSI codes. Load when determining the correct CSI code for a trade.
- **[references/exclusions.md](references/exclusions.md)** — Standard exclusions by trade. Load when writing exclusions for a specific trade.
- **[references/coordination.md](references/coordination.md)** — Critical trade intersections. Load when identifying coordination items between trades.
- **[references/preliminaries.md](references/preliminaries.md)** — Preparations & Preliminaries standard line items. Load when formatting the prelim/mobilization section.

## Quality Checklist

Before finalizing any line item, verify:

- Character count under 4,000
- Hyphens used (not asterisks or bullet symbols)
- Blank lines between scope items
- Measurements include units (SF, LF, EA, CY)
- Materials and specifications noted
- Exclusions listed
- No vendor pricing visible in client-facing output
- CSI code included
- Total price at bottom

## Local scope-writeup adaptation

Read ../../docs/CONTRACTS.md before generating scope. Use only accepted manifest quantities and source-linked dispositions; retain provisional quantities and conflicts in the client scope when material. No pricing, markup or cost research unless separately requested. Omit the total-price footer when price is unestablished or outside scope. Internal notes may contain only supplied vendor costs; never reveal those in client text. Generic exclusions and preliminary items are review prompts, not inferred scope. The CSI table is a legacy authoring convention; map to the project's chosen classification system, not a claimed current universal CSI standard. Enforce the strict plain-text rules on both outputs. No external import or sending is authorized.
