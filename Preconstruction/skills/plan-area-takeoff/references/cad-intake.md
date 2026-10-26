# DXF and DWG takeoff intake

Contents: routing/runtime; commands/review; measurement gates; takeoff integration; portable checks.

## Routing and runtime

Apply the same scope, design-coordination, quantity, topology and visual checks as PDF work. CAD adds precise coordinates, not reliable scope or automatic building semantics. Start with 2D architectural/structural/finish drawings; do not infer 3D assemblies from linework or flatten solids into measured areas.

Run `python <skill-dir>/scripts/cad.py capabilities` in the interpreter that will perform the takeoff. In ChatGPT, prefer `CODEX_PRIMARY_RUNTIME_PYTHON` when defined. Dependencies belong to the execution environment, not the skill archive. Check them each session; successful setup in an earlier container does not install them in a later container or in Prime.

| Source | Route | Required capability |
|---|---|---|
| DXF | Inspect native geometry; render; select evidence; extract | Python `ezdxf` (tested with 1.4.4) |
| DWG | Preserve original; convert separate copy to DXF; inventory and check fidelity | ODA File Converter plus a working headless runtime |
| PDF | Existing PDF/vector/raster calibration workflow | Existing PDF tools |
| DWG with no working converter | Attempt authorized environment setup, then use supplied DXF/PDF or ask for a DXF export and matching plot | Do not describe the DWG as read or measured |

If ezdxf is absent, install it into an isolated environment using the available package manager, then rerun capabilities. Do not treat a detected converter as a passed conversion test. Never send drawings to online conversion services without authorization.

ODA is external software, not bundled with this skill. Obtain the installer from the [official converter page](https://www.opendesign.com/guestfiles/oda_file_converter). On Linux its AppImage can be extracted with `--appimage-extract` in a dedicated tools directory when FUSE is unavailable. The resulting `squashfs-root/AppRun` is the executable. Preserve its accompanying libraries. Configure ezdxf's `[odafc-addon] unix_exec_path` to that absolute executable path, or expose the executable as `ODAFileConverter` on PATH. The helper uses ezdxf for discovery but invokes the ODA CLI directly, preserving stdout/stderr and `.err` sidecars. A headless Linux runtime needs a working `xvfb-run` or a compatible Qt minimal/offscreen runtime. Use supported environment installation or user-local extraction; if unavailable, state the limitation and use the fallback. Do not ship converter binaries, host-specific paths, or licenses in the skill.

For a Linux x86-64 runtime where display sockets are unavailable, use Qt's `minimal` platform without a display server. A tested combination is ODA AppImage 27.1 with Ubuntu Qt 6.2.4 libraries and matching plugins, extracted locally with `dpkg-deb -x` (no system package installation). The AppImage's own Qt build may not match distribution plugins despite matching version numbers: use the matching distribution Core/GUI/DBus libraries together. Required packages are:

| Official download base | Package files |
|---|---|
| `https://archive.ubuntu.com/ubuntu/pool/universe/q/qt6-base/` | `qt6-qpa-plugins_6.2.4+dfsg-2ubuntu1.1_amd64.deb`, `libqt6core6_6.2.4+dfsg-2ubuntu1.1_amd64.deb`, `libqt6gui6_6.2.4+dfsg-2ubuntu1.1_amd64.deb`, `libqt6dbus6_6.2.4+dfsg-2ubuntu1.1_amd64.deb` |
| `https://archive.ubuntu.com/ubuntu/pool/main/i/icu/` | `libicu70_70.1-2ubuntu1_amd64.deb` |
| `https://archive.ubuntu.com/ubuntu/pool/universe/libb/libb2/` | `libb2-1_0.98.1-1.1_amd64.deb` |

Keep downloads and extracted tools in a task tools directory, outside the skill. Resolve current official download links if these versions are unavailable. Extract the six `.deb` files to one `qt-root` directory, check unresolved dependencies with `ldd`, and set command-local environment values:

```bash
PATH="<directory-containing-ODAFileConverter>:$PATH" \
LD_LIBRARY_PATH="<qt-root>/usr/lib/x86_64-linux-gnu" \
QT_QPA_PLATFORM=minimal \
QT_QPA_PLATFORM_PLUGIN_PATH="<qt-root>/usr/lib/x86_64-linux-gnu/qt6/plugins/platforms" \
python <skill-dir>/scripts/cad.py convert original.dwg --output working.dxf
```

This is a reproducible runtime recipe, not a guarantee for all operating systems or future ODA releases. Check platform/library compatibility and run a known-geometry conversion before trusting a newly configured runtime. The user need not install local software for a GPT-hosted conversion when this runtime setup succeeds.

## Commands and required review

Commands print JSON; failure returns exit code 2 and an `error`. Capture successful results to task-local records; keep error responses out of measurement manifests. Output paths must be new, preferably dated and timestamped. Run `--help` for arguments.

```bash
python <skill-dir>/scripts/cad.py capabilities
python <skill-dir>/scripts/cad.py convert original.dwg --output working.dxf > conversion.json
python <skill-dir>/scripts/cad.py inspect working.dxf > inventory.json
python <skill-dir>/scripts/cad.py render working.dxf --layout Model --output review.svg
python <skill-dir>/scripts/cad.py extract working.dxf --handles 2F,30 --units in --basis '120 inch east-west and 144 inch north-south dimensions agree with geometry' --tolerance 0.01 > candidates.json
python <skill-dir>/scripts/cad.py annotate working.dxf --manifest candidates.json --output outlines.dxf
```

The dimension evidence above is an example, never a default basis. Select actual handles from the inspected file. Supported unit choices are in, ft, mm, cm and m; use an explicit conversion outside the helper for other units. Open curves produce lengths and null areas. Closed curves produce candidate areas and perimeters. A perimeter is not automatically baseboard, paint, or wall scope. The extraction helper deliberately accepts only selected direct modelspace LINE, LWPOLYLINE, planar POLYLINE, ARC, CIRCLE, ELLIPSE and SPLINE entities. It rejects block inserts, mesh geometry, tilted planes, paper-space entities, repeated handles and invalid closed polygons. Unsupported entities require the manual procedures below, not omission from scope.

The inventory lists layouts, layers, block definitions, insert transforms/arrays/attributes, text, dimension overrides, external dependencies and audit findings. It is an inventory, not an exhaustive semantic validator. Block contents and nested inserts still need inspection. Dependency `exists` only tests the recorded filesystem candidate; an unresolved Windows path may have a supplied equivalent elsewhere. Resolve using authorized project files, retaining the original and mapped paths. Fonts, plot styles, object enablers and custom-object appearance may need separate inspection.

The SVG is a fitted visual preview, not a calibrated measurement sheet. Convert it to PNG/PDF for visual review with the available artifact tools. Do not assume ezdxf reproduces AutoCAD plots exactly: text, proxy objects, hatches, clipped references and viewports need checking. ACIS solids and arbitrary 3D views are outside this renderer's coverage. Use a matching issued PDF or CAD plot when necessary; record the fallback's own measurement frame and confidence.

## Measurement gates

1. **Source and conversion:** Preserve original bytes. Record original and derived hashes, file revisions, converter/version, options, and logs. The helper records the converter executable hash, stdout/stderr and `.err` sidecars; record the installer/package version separately. Conversion defaults to audit/repair off on an isolated copy. If malformed source data prevents conversion, inspect the failure and rerun with `--audit-repair` to repair only the isolated working copy; retain both attempts and mark repair in the source register. Do not overwrite the original or assume repaired content is unchanged. A zero exit status alone is insufficient: parse the output and inspect every nonempty sidecar. Qt informational stderr may coexist with valid conversion; retain it without treating all stderr as fatal. Success proves a DXF was produced and parsed, not complete conversion. Check layouts, layers, entity types, dimensions, visible landmarks and dependencies against the original CAD application's plot or supplied PDF. A successful round trip alone does not prove fidelity. Keep affected quantities provisional when that comparison is unavailable.
2. **Units:** Verify `$INSUNITS` against independent horizontal/vertical dimensions and witness points. `$MEASUREMENT` is not the drawing's length-unit scale. A zero header means unspecified, not inches. Confirm dimension text overrides and model/insert scales. `--basis` records the agent's evidence; the helper cannot verify that evidence. Resolve `header_unit_conflict` before accepting quantities. Do not force agreement with a PDF or an area label.
3. **Spaces and visibility:** Measure intended model geometry once, not every sheet viewport. Inventory paper-space-only details and calibrate those separately. Off/frozen/nonplot layers, viewport-specific freezes, XCLIP, WIPEOUT, design options and demolition layers need explicit dispositions. A layer name is a classification hint, never proof of installation scope. Avoid counting block definitions, legends, schedules and repeated views as physical instances.
4. **Blocks and references:** Resolve nested xrefs and inserts recursively with a cycle guard. Maintain the complete instance chain, base point, translation, rotation, XYZ scales, OCS-to-WCS transform and array row/column identity. Nonuniform or negative scales change geometry. Do not measure untransformed definition coordinates. `INSERT.virtual_entities()` can aid controlled extraction but its skipped-entity callback, array expansion, clipping and dynamic/proxy limitations require review. Work in a derived copy and retain original instance provenance if exploding selected geometry. The helper does not automatically bind or expand blocks/xrefs.
5. **Boundaries and curves:** Select finished faces for flooring, not wall centerlines or bounding boxes. Inspect open endpoints before joining lines; record snapping tolerance and each repaired gap. Do not close an open room automatically or use hatch extents as room area. Preserve hatch islands and holes explicitly. The helper approximates curves through ezdxf paths; halve `--tolerance` and compare area/length until the change is immaterial at the declared reporting precision. Distance is in native drawing units, not feet. Record both runs and retain the finer vertices. High-precision curves may require analytic geometry or denser sampling; the flattening parameter alone is not a universal error guarantee.
6. **Physical planes:** Preserve WCS and each entity's elevation. Constant elevation is acceptable for an XY measurement plane, but different floors remain separate. Never pool coincident XY polygons from different floors or flatten inclined roof/elevation surfaces. Establish a documented local plane and transform for those surfaces outside this helper.

## Integrate with the existing takeoff records

Keep `geometry.py`'s schema unchanged. Candidate records are evidence in the outer project manifest, not finished quantities. Add room, trade, scope status, finish, physical plane, gross/deduction/addback roles, evidence and question IDs. Use source hash plus handle and full instance path as provenance; handles alone are not stable across files or conversion.

For an accepted closed boundary, copy its stored `pts` into an area-helper polygon. Set `scale = 1 / feet_per_unit`, `length_unit = ft`, `area_unit = SF`, and explicitly retain the CAD WCS coordinate frame. Keep one plane per manifest. Link a quantity ID to its candidate ID. Routes use the same stored vertices and recorded curve tolerance; counts use deduplicated physical instances with point locators. Preserve gross, deductions, net, waste and ordering as separate fields. Check overlaps, containment, missing rooms and scope coverage exactly as for PDF work.

The annotation command creates **outline-only** TAKEOFF_GEOMETRY and TAKEOFF_LABELS layers from the stored vertices in a new DXF. It rejects a changed source hash and existing takeoff layers. It does not calculate Boolean net fill, deductions, quantity legends or final scope schedules. Add those from the authoritative project manifest during delivery; do not present candidate outlines as a completed overlay. Generate net-only fills after topology checks, label provisional marks, and use the same IDs/quantities/styles in CAD, PDF and workbook legends.

For final PDF overlays, render the annotated CAD in one operation or record the exact CAD-to-page transform, including Y inversion, scale, translation, crop and layout. Never overlay raw CAD coordinates on an auto-fitted SVG/PDF. Verify landmarks and every measured zone after export. Preserve the existing source register and callout/RFI closure requirements.

When CAD and PDF disagree, retain both revisions and evidence. Neither native coordinates nor the later date automatically governs design intent. Use the user's source hierarchy or raise a specific conflict. Continue supported measurements while identifying affected quantities.

## Portable checks

Run `python <skill-dir>/scripts/test_cad.py` and `python <skill-dir>/scripts/test_geometry.py` after changes. The SVG-to-image regression also requires PyMuPDF (`fitz`). These synthetic tests validate helper behavior, not a project's scope. With ODA configured on PATH and the applicable runtime environment, set `TAKEOFF_TEST_ODA=1` to enable the real DXF-to-DWG-to-DXF known-area test; otherwise it is explicitly skipped. Also perform a project DWG conversion-and-render smoke test when available. Record what actually ran; conversion availability must be rechecked in each runtime.

Reference APIs: [ezdxf](https://ezdxf.readthedocs.io/en/stable/), [ODA integration](https://ezdxf.readthedocs.io/en/stable/addons/odafc.html), [drawing limitations](https://ezdxf.readthedocs.io/en/stable/addons/drawing.html), [paths](https://ezdxf.readthedocs.io/en/stable/path.html).
