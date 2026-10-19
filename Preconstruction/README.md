# Preconstruction workflows for mlx-local

Version 0.1.0 • staged 2026-10-19 • purpose-built local workflow, no OpenTakeoff MCP.

This package preserves eight existing skill sources, their references, the deterministic area/CAD helpers and an empty project template. It adds portable configuration, synthetic fixtures, contract tests and a development specification. It does **not** implement a finished mlx-local takeoff application or certify quantities/code compliance. No customer drawings, customer examples, weights or credentials are included.

Start with [inventory](docs/INVENTORY.md), [architecture](docs/ARCHITECTURE.md), [roadmap](docs/ROADMAP.md), [acceptance](docs/ACCEPTANCE.md) and the [Claude prompt](CLAUDE-DEVELOPMENT-PROMPT.md). [Contracts](docs/CONTRACTS.md) govern the local adaptations. The [source manifest](provenance/source-manifest.json) records exact input/output hashes and edits. [Dependency notes](DEPENDENCIES.md) distinguish required from optional software and observed availability.

## Add to the repo

Place this entire directory at `mlx-local/Preconstruction/` after reviewing the live checkout. Do not overwrite existing files or include customer project data in source control. No automatic installer is supplied. Keep one canonical `skills/` tree. Claude can read it explicitly; existing `SKILL.md` frontmatter and relative references are preserved. If native discovery is desired, add individually reviewed repo-local `.claude/skills/<name>` links/copies pointing here; do not change global skill directories. Codex discovery can similarly use repo-local `.agents/skills`. Avoid creating two editable authorities.

Configure `PRECONSTRUCTION_WORKSPACE` to a user-selected project-data directory outside the repo. `${...}` in documents means an explicit configuration placeholder, not an expanded value. No sample path grants access. `TAKEOFF_PYTHON` optionally selects an already-installed Python for CAD helpers; ODA must be separately available on that process's PATH and verified by conversion before use. Blender is optional and disabled by default. No Prime/Claude process is launched by this package.

## Lightweight validation

From this package directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_contracts.py
PYTHONDONTWRITEBYTECODE=1 python3 skills/plan-area-takeoff/scripts/test_geometry.py
PYTHONDONTWRITEBYTECODE=1 python3 tools/verify_package.py
```

For optional CAD/render tests, use an already configured interpreter with ezdxf and PyMuPDF:

```sh
PYTHONDONTWRITEBYTECODE=1 "$TAKEOFF_PYTHON" skills/plan-area-takeoff/scripts/test_cad.py
```

The optional `tests/test_optional_checks.py` additionally needs jsonschema, Shapely and PyMuPDF. It independently checks fixture topology, schema and rendered hole pixels. Regenerate optional scans/crops with `tools/generate_raster_fixtures.py` using that existing runtime.

No install, benchmark, server, network or model load is required for the core checks. Synthetic fixtures are hand-authored evidence and do not imply model extraction was tested. Current results and limitations are in [validation](validation/REPORT.md). Full application acceptance remains Claude's work.

## Authority and release

Immutable sources → registered views/calibration → interpreted candidates → reviewed deterministic geometry/quantities → paired draft scope/overlays/workbook → explicit human release. Unknown is null, not zero. Existing/retained, removal, new, alternatives and provisional work remain separate. Human approvals bind an artifact hash and a limited decision scope; changed inputs invalidate affected approvals. Never infer engineering, field, fabrication, procurement or code approval from a rendering, arithmetic pass or owner design choice.
