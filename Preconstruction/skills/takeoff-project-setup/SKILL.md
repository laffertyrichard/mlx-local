---
name: takeoff-project-setup
description: Set up a named takeoff project in the takeoff-skill-codex workspace, stage supplied plans and scope documents, register source provenance, and save an intake checkpoint. Use for creating a project folder or adding source files before measurement; setup alone does not authorize quantities, pricing, or a full takeoff.
---

# Takeoff project setup

Create a project that can be resumed from disk: the standard folder structure, an accurate source inventory, and an explicit next action. Support both an empty project awaiting plans and a project with supplied documents. Accept documents at any time; folder creation or a handoff is not a prerequisite for intake.

## Locate the workspace and requested project

Use the explicitly configured `PRECONSTRUCTION_WORKSPACE` project-data root. Never default to the source authoring checkout; it is provenance only. Keep project data outside the source repo unless the user explicitly selects a repo-local data root. Resolve this package root from the skill directory (`../..`). Read the package `AGENTS.md`, `README.md`, and `templates/project/README.md`, plus any instructions at the explicitly configured project-data root, before changing files. Use the bundled package template read-only; the data root need not contain a duplicate template. Reuse the existing template and helpers; do not reconstruct their schemas. If these are missing, report the missing prerequisite and preserve received files in an authorized location rather than claiming standard setup is complete.

Use the user's project name and stated scope, exclusions, source locations, and requested deliverables. Ask for a missing project name; other unknown intake fields can remain explicitly unestablished. Preliminary plans establish a preliminary source basis, not bid readiness. Do not infer full trade takeoffs or pricing from a setup request.

New projects belong in a named direct child of the root. Verify the destination remains inside that root; reject path traversal or a symlink destination that escapes it. Copy the package-root `templates/project` only to a new unused destination under the configured data root, with overwrite disabled. Do not create a new Codex chat merely to create a folder.

If the requested folder already exists, inspect it first. Continue intake in that folder when requested, preserving existing sources, IDs, manifests, and outputs. For a user-created empty or partial folder, add only missing template items; do not nest another `project` folder or replace existing records. If the user explicitly wants a separate new project with a colliding name, ask for an unused name. Do not migrate other projects or existing ChatGPT takeoff conversations.

## Stage received sources

1. Inventory the files actually supplied or accessible at the user's source location. Plans, written scope/general notes, specifications, schedules, and addenda are separate source records. Preserve original filenames and bytes. A browser preview, attachment chip, Finder selection, or drag gesture does not prove local placement.
2. Copy received files into `<project>/sources/originals/`; leave the source location intact. Dropbox prospect paths such as `uploads/plans` or `bid_docs/interior_design_bid_set_kmd` are input locations, not alternative local project structures. Confirm cloud files can actually be read; record an unavailable placeholder as pending, without claiming it was copied. Use existing supported access; install no dependencies or converters and change no security settings.
3. Originals are immutable. Before a same-name copy, compare hashes: reuse the existing file if identical; otherwise retain both under distinct filenames and record the revision relationship. Never overwrite a source, including a superseded revision. Put later converted, cropped, rotated, or extracted files in `sources/derived`, linked to the original hash and transform.
4. Read each staged file back, confirm it is nonempty, and compute SHA-256. Compare source and destination hashes when both are readable. For PDFs, use an installed parser to check openability and page count; record warnings, encryption, or unavailable checks honestly. Do not infer successful DWG conversion from capability detection.
5. When plans will arrive later, create the project now and record `awaiting sources`. List promised filenames only as pending intake in the README/checkpoint; do not give nonexistent files verified hashes or received status. Continue with the accessible subset when a source is missing.

Keep every project source, register, measurement, calculation, overlay, working output, validation result, checkpoint, revision, and deliverable inside that project's folder. If the user explicitly supplies prior takeoffs for retention, copy them into a dated revision folder, retain their original filenames and known verification limits, and link them from the checkpoint. Importing an output does not validate it.

## Fill the existing intake records

Update `<project>/README.md` with the project name, requested scope/exclusions, received revisions, requested deliverables, current checkpoint, pending sources, and next action. Leave unspecified fields explicitly unestablished.

Populate `registers/sources.csv` using its existing header:

`source_id,filename,sha256,revision_date,sheet_slide,file_page,applicability,review_status,missing_references,derived_from,transform`

- Allocate stable source IDs without renumbering prior records. Repeated sheet/page rows for the same file share its source ID and hash.
- Record the actual staged filename/path consistently with the project's convention. Distinguish printed sheet/slide labels from actual file pages; state page numbering conventions.
- Record document revision/date from the source where established. A filename date or filesystem modification date does not settle a conflicting printed revision; keep that discrepancy visible in the checkpoint.
- Label intake checks precisely, for example `received; hash verified; PDF opens; content review pending`. Structural checks do not establish visual review, scope coverage, or measurement accuracy.
- Record missing referenced documents only when source evidence establishes them. Do not invent required trades or missing designs.

Set the project name, supplied scope, revision, and checkpoint path in `measurements/project-manifest.json` while retaining its schema and relative register links. During setup, leave `plane_manifests` and `quantities` empty; on existing projects, preserve their contents. Later measurement uses separate plane manifests under the shared area helper's schema.

Retain the template's coverage, callout, question, unfinished-measurement, and validation registers. Fill entries only when supported by actual intake evidence. Awaiting plans is an intake state; depicted work awaiting measurement later belongs in `unfinished-measurements.csv`, not a missing-design RFI. Unknown quantities remain unestablished, never zero.

## Verify and checkpoint

Before revising an existing project, save a dated/versioned checkpoint of the affected records and prior outputs. At completed intake, use `checkpoints/checkpoint-template.md` to save a new dated/versioned checkpoint and point the README and project manifest to it. Include completed work, exact source/register/output paths, checks and limits, pending sources, open questions, and next action. Do not overwrite an earlier checkpoint.

Save intake evidence under `validation` and reference it from `registers/validation.csv`. Check:

- The project is a direct child of the root and contains the template's directories and records.
- Each received source has a readable destination, SHA-256, and matching register entry; every register path and manifest/checkpoint link resolves. Pending sources are clearly distinguished from received sources.
- JSON and CSV records parse, existing IDs/data are retained, and originals have not been altered by processing.
- PDF openability/page counts and source-copy comparisons have explicit passed, failed, or unavailable results. Drawing review and measurement checks remain pending unless separately performed.

Report the absolute project path, received file count and filenames, pending files, checkpoint path, and intake-check limits. An empty project can be successfully created while source staging remains pending. Claim all supplied sources are staged only after verifying the files individually.

For Codex discovery, open the workspace or a project beneath it in a new turn. If app registration is needed, use the existing project entry or add the root through the app's supported UI; let the user handle any folder-trust prompt. Do not change security settings or claim registration was completed without observing it.

If measurement was also requested, continue with [plan-area-takeoff](../plan-area-takeoff/SKILL.md) and read [design coordination](../plan-area-takeoff/references/design-coordination.md) before measuring. Otherwise finish at the intake checkpoint.

For a sanitized summary of workflow rationale, read [recorded workflow](references/recorded-workflow.md). No customer history is packaged or required.
