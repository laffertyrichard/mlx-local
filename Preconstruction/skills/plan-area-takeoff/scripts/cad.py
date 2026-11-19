"""Conservative 2D CAD intake. Run with --help. Requires ezdxf; DWG needs ODA.

Extracted entities are candidate geometry, never an automatic scope takeoff.
Original files are read only; all outputs must be new paths.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from geometry import signed_area, validate_polygon

UNIT_CODES = {'in': 1, 'ft': 2, 'mm': 4, 'cm': 5, 'm': 6}
SUPPORTED = {'LINE', 'LWPOLYLINE', 'POLYLINE', 'ARC', 'CIRCLE', 'ELLIPSE', 'SPLINE'}


def source_record(filename):
    p = Path(filename).resolve()
    return {'file': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}


def new_output(filename):
    p = Path(filename).resolve()
    if p.exists():
        raise ValueError('Output already exists; use a new timestamped output path')
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def load(filename):
    import ezdxf
    if Path(filename).suffix.lower() != '.dxf':
        raise ValueError('Convert DWG to a separate DXF first; do not rename extensions')
    return ezdxf.readfile(filename)


def capabilities():
    import importlib.util
    available = importlib.util.find_spec('ezdxf') is not None
    oda = False
    version = None
    if available:
        import ezdxf
        from ezdxf.addons import odafc
        version = ezdxf.__version__
        oda = odafc.is_installed()
    return {'ezdxf': available, 'ezdxf_version': version, 'oda_detected': oda,
            'dwg_conversion': 'requires actual conversion smoke test' if oda else 'unavailable',
            'python': sys.executable, 'xvfb_run': shutil.which('xvfb-run')}


def inspect_dxf(filename):
    doc = load(filename)
    records, dependencies = [], []
    layouts = []
    for layout in doc.layouts:
        items = list(layout)
        layouts.append({'name': layout.name, 'entity_counts': dict(Counter(e.dxftype() for e in items))})
        for e in items:
            r = {'handle': e.dxf.handle, 'type': e.dxftype(), 'layer': e.dxf.get('layer'), 'layout': layout.name}
            if e.dxftype() == 'INSERT':
                r['insert'] = {'name': e.dxf.name, 'point': list(e.dxf.insert),
                               'scale': [e.dxf.xscale, e.dxf.yscale, e.dxf.zscale], 'rotation': e.dxf.rotation,
                               'rows': e.dxf.row_count, 'columns': e.dxf.column_count,
                               'attributes': [{'tag': a.dxf.tag, 'text': a.dxf.text} for a in e.attribs]}
            if e.dxftype() in {'TEXT', 'MTEXT'}:
                r['text'] = e.plain_text()
            if e.dxftype() == 'DIMENSION':
                r['dimension_text'] = e.dxf.get('text', '')
                r['dimension_override_review'] = r['dimension_text'] not in ('', '<>')
            records.append(r)
    blocks = []
    for block in doc.blocks:
        b = block.block
        blocks.append({'name': block.name, 'base_point': list(b.dxf.base_point),
                       'entity_counts': dict(Counter(e.dxftype() for e in block)),
                       'handles': [e.dxf.handle for e in block]})
        if b.dxf.get('xref_path', ''):
            dependencies.append({'kind': 'xref', 'block': block.name, 'path': b.dxf.xref_path})
    for e in doc.objects:
        if e.dxftype() in {'IMAGEDEF', 'PDFDEFINITION', 'DWFDEFINITION', 'DGNDEFINITION'}:
            dependencies.append({'kind': e.dxftype(), 'path': e.dxf.get('filename', '')})
    for d in dependencies:
        raw = Path(d['path'].replace('\\', '/'))
        local = raw if raw.is_absolute() else Path(filename).resolve().parent / raw
        d.update(resolved_candidate=str(local), exists=local.is_file())
    auditor = doc.audit()
    return {'source': source_record(filename), 'dxf_version': doc.dxfversion,
            'insunits': doc.units, 'measurement_header': doc.header.get('$MEASUREMENT'),
            'layouts': layouts, 'layers': [{'name': l.dxf.name, 'off': l.is_off(), 'frozen': l.is_frozen(),
                                          'plot': l.dxf.get('plot', 1)} for l in doc.layers],
            'blocks': blocks, 'dependencies': dependencies, 'entities': records,
            'audit': {'errors': len(auditor.errors), 'in_memory_fixes': len(auditor.fixes)},
            'review_required': ['Verify units against independent dimensions',
                                'Resolve references and inspect nested blocks, clipping, dynamic/proxy objects',
                                'Distinguish visible sheet scope from model geometry and repeated views',
                                'Entity inventory is not a quantity schedule; audit does not prove completeness']}


def extract(filename, handles, units, basis, tolerance):
    from ezdxf import path, units as cad_units
    if units not in UNIT_CODES or not basis or not basis.strip():
        raise ValueError('Explicit --units and --basis dimension evidence are required')
    if not math.isfinite(tolerance) or tolerance <= 0:
        raise ValueError('Tolerance must be a positive finite distance in drawing units')
    ids = [h.strip().upper() for h in handles.split(',') if h.strip()]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError('Select unique nonempty entity handles')
    doc = load(filename)
    model_handles = {e.dxf.handle for e in doc.modelspace()}
    factor = cad_units.conversion_factor(UNIT_CODES[units], 2)
    records = []
    for handle in ids:
        if handle not in model_handles:
            raise ValueError(f'{handle}: only direct modelspace entities may be extracted by this helper')
        e = doc.entitydb[handle]
        if e.dxftype() not in SUPPORTED:
            raise ValueError(f'{handle}: {e.dxftype()} requires separate interpretation or block transformation')
        if e.dxftype() == 'POLYLINE' and (e.is_polygon_mesh or e.is_poly_face_mesh):
            raise ValueError(f'{handle}: mesh is not a planar boundary')
        if e.dxf.hasattr('extrusion'):
            n = e.dxf.extrusion
            if abs(n.x) > 1e-10 or abs(n.y) > 1e-10:
                raise ValueError(f'{handle}: inclined geometry needs an explicit measurement plane')
        p = path.make_path(e)
        vertices = list(p.flattening(distance=tolerance, segments=8))
        if len(vertices) < 2 or any(not all(math.isfinite(c) for c in v) for v in vertices):
            raise ValueError(f'{handle}: invalid or empty geometry')
        if max(v.z for v in vertices) - min(v.z for v in vertices) > 1e-8:
            raise ValueError(f'{handle}: nonplanar geometry needs a separate measurement plane')
        pts = [[v.x, v.y] for v in vertices]
        # Path.is_closed uses relative endpoint proximity: at large WCS values
        # that can seal a real gap. Trust the entity's declared topology instead.
        kind = e.dxftype()
        closed = (kind == 'CIRCLE' or
                  (kind in {'LWPOLYLINE', 'SPLINE'} and bool(e.closed)) or
                  (kind == 'POLYLINE' and bool(e.is_closed)) or
                  (kind == 'ELLIPSE' and math.isclose(abs(e.dxf.end_param - e.dxf.start_param),
                                                     2 * math.pi, rel_tol=0, abs_tol=1e-12)))
        if closed and pts[0] == pts[-1]:
            pts.pop()
        if closed:
            validate_polygon(pts)
        pairs = list(zip(pts, pts[1:])) + ([(pts[-1], pts[0])] if closed else [])
        length = sum(math.dist(a, b) for a, b in pairs)
        records.append({'id': f'CAD-{handle}', 'handle': handle, 'layer': e.dxf.layer,
                        'type': e.dxftype(), 'layout': 'Model', 'closed': closed, 'pts': pts,
                        'plane_z': vertices[0].z, 'length_ft': length * factor,
                        'area_sf': abs(signed_area(pts)) * factor**2 if closed else None,
                        'status': 'candidate_not_scope_approved'})
    return {'source': source_record(filename), 'coordinate_system': 'CAD WCS XY; native drawing units; y up',
            'insunits': doc.units, 'selected_units': units, 'basis': basis,
            'header_unit_conflict': doc.units not in (0, UNIT_CODES[units]),
            'feet_per_unit': factor, 'curve_flattening_distance': tolerance,
            'entities': records, 'validation': {'checked': ['selected modelspace handles', 'planarity',
                  'simple closed polygons', 'explicit units and basis', 'geometry arithmetic'],
                  'not_checked': ['scope', 'unit evidence truth', 'cross-entity topology', 'curve convergence',
                                  'external references', 'conversion fidelity', 'visibility or clipping']}}


def render(filename, output, layout_name):
    from ezdxf.addons.drawing import Frontend, RenderContext, svg, layout
    doc = load(filename)
    target = doc.layouts.get(layout_name)
    if Path(output).suffix.lower() != '.svg':
        raise ValueError('Use .svg for the preview; convert to PDF/PNG with available artifact tools')
    backend = svg.SVGBackend()
    Frontend(RenderContext(doc), backend).draw_layout(target, finalize=True)
    data = backend.get_string(layout.Page(420, 297))
    # Some PDF/raster SVG readers omit class-based styles across multiple style
    # elements. Inline this backend's simple generated styles before delivery.
    ET.register_namespace('', 'http://www.w3.org/2000/svg')
    root = ET.fromstring(data)
    styles = {}
    for style in root.findall('.//{http://www.w3.org/2000/svg}style'):
        for name, body in re.findall(r'\.([\w-]+)\s*\{([^}]+)\}', style.text or ''):
            styles[name] = dict(pair.strip().split(':', 1) for pair in body.split(';') if ':' in pair)
    for element in root.iter():
        for cls in element.attrib.pop('class', '').split():
            for key, value in styles.get(cls, {}).items():
                if key != 'stroke-width' or value.strip() != 'none':
                    element.set(key, value.strip())
    data = ET.tostring(root, encoding='unicode')
    new_output(output).write_text(data)
    return {'output': str(Path(output).resolve()), 'layout': layout_name,
            'warning': 'Fitted review preview: do not scale. Not proof of CAD rendering completeness.'}


def annotate(filename, manifest, output):
    doc = load(filename)
    data = json.loads(Path(manifest).read_text())
    if data['source']['sha256'] != source_record(filename)['sha256']:
        raise ValueError('Source changed since extraction; regenerate geometry')
    if data['coordinate_system'] != 'CAD WCS XY; native drawing units; y up':
        raise ValueError('Annotation requires the native CAD coordinate frame')
    if Path(output).suffix.lower() != '.dxf':
        raise ValueError('Annotated output must be DXF')
    for name, color in [('TAKEOFF_GEOMETRY', 3), ('TAKEOFF_LABELS', 2)]:
        if name in doc.layers:
            raise ValueError('Existing TAKEOFF layers require explicit reconciliation; use original source')
        doc.layers.new(name, dxfattribs={'color': color})
    ids = set()
    for r in data['entities']:
        if r['id'] in ids:
            raise ValueError('Duplicate annotation ID')
        ids.add(r['id'])
        pts = r['pts']
        if len(pts) < 2 or any(len(p) != 2 or not all(math.isfinite(c) for c in p) for p in pts):
            raise ValueError('Invalid annotation coordinates')
        if r['closed']:
            validate_polygon(pts)
        doc.modelspace().add_lwpolyline(pts, close=r['closed'], dxfattribs={
            'layer': 'TAKEOFF_GEOMETRY', 'elevation': r['plane_z']})
        doc.modelspace().add_text(r['id'], dxfattribs={'layer': 'TAKEOFF_LABELS',
            'insert': (*pts[0], r['plane_z']), 'height': 0.2 / data['feet_per_unit']})
    out = new_output(output)
    doc.saveas(out)
    return {'output': str(out), 'marks': len(ids), 'warning': 'Outline geometry only; no net fill or scope approval implied'}


def convert(source, output, timeout, audit_repair=False):
    from ezdxf.addons import odafc
    if Path(source).suffix.lower() != '.dwg' or Path(output).suffix.lower() != '.dxf':
        raise ValueError('Conversion requires DWG source and new DXF output')
    if not odafc.is_installed():
        raise ValueError('DWG converter unavailable. Obtain a DXF export and matching PDF, or install ODA File Converter in this runtime.')
    out = new_output(output)
    original = source_record(source)
    import platform
    configured = odafc.get_win_exec_path() if platform.system() == 'Windows' else odafc.get_unix_exec_path()
    executable = configured if configured and Path(configured).is_file() else shutil.which('ODAFileConverter')
    converter_identity = source_record(executable) if executable else {'file': 'not resolved'}
    # Convert an isolated copy; never audit, repair or overwrite the user's original.
    # Invoke ODA directly: ezdxf's adapter treats benign Qt stderr as a failure
    # even when ODA exits 0 and produces a valid DXF, and hides successful logs.
    with tempfile.TemporaryDirectory(prefix='takeoff-cad-') as temp:
        inputs = Path(temp) / 'input'
        outputs = Path(temp) / 'output'
        inputs.mkdir()
        outputs.mkdir()
        src = inputs / 'source.dwg'
        dst = outputs / 'source.dxf'
        shutil.copyfile(source, src)
        command = [executable, str(inputs), str(outputs), 'ACAD2018', 'DXF', '0', str(int(audit_repair)), src.name]
        if (platform.system() == 'Linux' and not os.environ.get('DISPLAY') and
                os.environ.get('QT_QPA_PLATFORM') not in {'minimal', 'offscreen'}):
            if not shutil.which('xvfb-run'):
                raise ValueError('Headless ODA needs xvfb-run or a tested Qt minimal/offscreen runtime')
            command = [shutil.which('xvfb-run'), '-a', *command]
        result = subprocess.run(command,
                                capture_output=True, text=True, timeout=timeout)
        sidecars = {p.name: p.read_text(errors='replace') for p in outputs.glob('*.err')}
        if result.returncode or not dst.is_file():
            raise ValueError('ODA conversion failed: ' + result.stderr[-1500:] + str(sidecars))
        try:
            load(dst)
        except Exception as error:
            raise ValueError('Converted DXF is invalid: ' + str(error) + '; ODA reports: ' + str(sidecars)) from error
        shutil.copyfile(dst, out)
    return {'source': original, 'derived': source_record(out), 'converter': 'ODA File Converter CLI',
            'converter_identity': converter_identity,
            'converter_version': 'not automatically available; record installer/package version separately',
            'logs': {'stdout': result.stdout, 'stderr': result.stderr, 'sidecars': sidecars},
            'output_version': 'R2018', 'audit_repair': audit_repair,
            'review_required': 'Inventory references, compare to source plots and verify dimensions before measuring'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['capabilities', 'inspect', 'extract', 'render', 'annotate', 'convert'])
    parser.add_argument('source', nargs='?')
    parser.add_argument('--output')
    parser.add_argument('--handles', help='Comma-separated direct modelspace entity handles')
    parser.add_argument('--units', choices=UNIT_CODES)
    parser.add_argument('--basis', help='Independent dimension checks and resolved unit conflicts')
    parser.add_argument('--tolerance', type=float, default=0.01, help='Curve flattening distance in drawing units; verify convergence')
    parser.add_argument('--layout', default='Model')
    parser.add_argument('--manifest')
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('--audit-repair', action='store_true', help='Run ODA audit/repair on an isolated copy; record and review changes')
    args = parser.parse_args()
    try:
        if args.command == 'capabilities':
            result = capabilities()
        else:
            if not args.source:
                raise ValueError('Source file is required')
            if args.command in {'render', 'annotate', 'convert'} and not args.output:
                raise ValueError('--output is required')
            if args.command == 'inspect':
                result = inspect_dxf(args.source)
            elif args.command == 'extract':
                if not args.handles:
                    raise ValueError('--handles is required')
                result = extract(args.source, args.handles, args.units, args.basis, args.tolerance)
            elif args.command == 'render':
                result = render(args.source, args.output, args.layout)
            elif args.command == 'annotate':
                if not args.manifest:
                    raise ValueError('--manifest is required')
                result = annotate(args.source, args.manifest, args.output)
            else:
                result = convert(args.source, args.output, args.timeout, args.audit_repair)
        print(json.dumps(result, indent=2, allow_nan=False))
    except Exception as error:
        print(json.dumps({'error': str(error), 'type': type(error).__name__}))
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
