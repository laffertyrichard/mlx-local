"""Regression cases for CAD quantities and unsafe measurement bases."""
import json
import math
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

import ezdxf

SCRIPT = Path(__file__).with_name('cad.py')


class CADTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.doc = ezdxf.new('R2018', units=1)
        self.msp = self.doc.modelspace()
        self.rect = self.msp.add_lwpolyline([(0, 0), (120, 0), (120, 144), (0, 144)], close=True)
        self.file = self.root / 'source.dxf'

    def tearDown(self):
        self.temp.cleanup()

    def run_cad(self, *args, ok=True):
        if not self.file.exists():
            self.doc.saveas(self.file)
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if ok else 2, result.stderr)
        return json.loads(result.stdout)

    def extract(self, handles=None, **kw):
        return self.run_cad('extract', self.file, '--handles', handles or self.rect.dxf.handle,
                            '--units', 'in', '--basis', 'Verified 120 inch horizontal and 144 inch vertical dimensions',
                            '--tolerance', '0.01', **kw)

    def test_rect_area_and_length_use_declared_real_units(self):
        r = self.extract()['entities'][0]
        self.assertAlmostEqual(r['area_sf'], 120)
        self.assertAlmostEqual(r['length_ft'], 44)
        self.assertEqual(r['handle'], self.rect.dxf.handle)

    def test_open_polyline_has_no_area(self):
        self.rect.closed = False
        r = self.extract()['entities'][0]
        self.assertIsNone(r['area_sf'])
        self.assertAlmostEqual(r['length_ft'], 32)

    def test_large_coordinate_open_gap_is_not_closed(self):
        self.rect.closed = False
        b = 1e9
        self.rect.set_points([(b, b), (b + 120, b), (b + 120, b + 144), (b, b + 144), (b, b + 0.5)])
        r = self.extract()['entities'][0]
        self.assertFalse(r['closed'])
        self.assertIsNone(r['area_sf'])

    def test_bulge_curve_not_chord(self):
        arc = self.msp.add_lwpolyline([(0, 0, 1), (24, 0, 0)], format='xyb', close=True)
        r = self.extract(arc.dxf.handle)['entities'][0]
        self.assertAlmostEqual(r['area_sf'], math.pi / 2, delta=0.002)
        self.assertAlmostEqual(r['length_ft'], math.pi + 2, delta=0.002)

    def test_inclined_geometry_is_rejected(self):
        self.rect.dxf.extrusion = (0, 1, 1)
        self.assertIn('error', self.extract(ok=False))

    def test_self_intersection_is_rejected(self):
        self.rect.set_points([(0, 0), (100, 100), (0, 100), (100, 0)])
        self.assertIn('error', self.extract(ok=False))

    def test_duplicate_handles_are_rejected(self):
        self.extract(self.rect.dxf.handle + ',' + self.rect.dxf.handle, ok=False)

    def test_paperspace_measurement_is_rejected(self):
        e = self.doc.layouts.new('Sheet').add_circle((0, 0), 12)
        self.extract(e.dxf.handle, ok=False)

    def test_block_is_reported_not_automatically_measured(self):
        block = self.doc.blocks.new('fixture')
        block.add_circle((0, 0), 1)
        e = self.msp.add_blockref('fixture', (10, 20), dxfattribs={'xscale': 2, 'rotation': 90})
        r = self.run_cad('inspect', self.file)
        b = next(x for x in r['entities'] if x['handle'] == e.dxf.handle)
        self.assertEqual(b['insert']['scale'], [2, 1, 1])
        self.extract(e.dxf.handle, ok=False)

    def test_missing_xref_and_dimension_override_are_reported(self):
        block = self.doc.blocks.new('external', dxfattribs={'flags': 4, 'xref_path': 'missing.dwg'})
        self.msp.add_blockref(block.name, (0, 0))
        self.msp.add_linear_dim(base=(0, -10), p1=(0, 0), p2=(120, 0), text='11 ft').render()
        r = self.run_cad('inspect', self.file)
        self.assertTrue(any(x['path'] == 'missing.dwg' and not x['exists'] for x in r['dependencies']))
        self.assertTrue(any(x.get('dimension_text') == '11 ft' for x in r['entities']))

    def test_unitless_requires_explicit_basis(self):
        self.doc.units = 0
        r = self.run_cad('inspect', self.file)
        self.assertEqual(r['insunits'], 0)
        self.run_cad('extract', self.file, '--handles', self.rect.dxf.handle, ok=False)

    def test_render_produces_svg(self):
        output = self.root / 'preview.svg'
        self.run_cad('render', self.file, '--output', output)
        self.assertIn('<svg', output.read_text())

    def test_svg_preview_line_survives_pdf_renderer(self):
        import fitz
        self.msp.delete_entity(self.rect)
        self.msp.add_line((0, 0), (120, 144))
        self.msp.add_line((10, 0), (130, 144), dxfattribs={'color': 1})
        output = self.root / 'line.svg'
        self.run_cad('render', self.file, '--output', output)
        with fitz.open(output) as drawing:
            pix = drawing[0].get_pixmap()
            pixels = pix.samples
            red = sum(pixels[i] > 150 and pixels[i+1] < 100 and pixels[i+2] < 100
                      for i in range(0, len(pixels), pix.n))
            self.assertGreater(red, 100)

    def test_circle_in_mm_measures_in_feet(self):
        self.doc.units = 4
        e = self.msp.add_circle((0, 0), 304.8)
        r = self.run_cad('extract', self.file, '--handles', e.dxf.handle, '--units', 'mm',
                         '--basis', '609.6 mm verified diameter', '--tolerance', '0.01')['entities'][0]
        self.assertAlmostEqual(r['area_sf'], math.pi, delta=0.002)
        self.assertAlmostEqual(r['length_ft'], 2 * math.pi, delta=0.002)

    def test_dimension_cannot_be_measured_as_boundary(self):
        e = self.msp.add_linear_dim(base=(0, -10), p1=(0, 0), p2=(120, 0)).dimension
        self.extract(e.dxf.handle, ok=False)

    def test_existing_output_is_not_overwritten(self):
        output = self.root / 'preview.svg'
        output.write_text('preserve this')
        self.run_cad('render', self.file, '--output', output, ok=False)
        self.assertEqual(output.read_text(), 'preserve this')

    def test_changed_source_cannot_use_stale_annotations(self):
        record = self.extract()
        manifest = self.root / 'measure.json'
        manifest.write_text(json.dumps(record))
        self.msp.add_line((0, 0), (1, 1))
        self.doc.saveas(self.file)
        self.run_cad('annotate', self.file, '--manifest', manifest,
                     '--output', self.root / 'marked.dxf', ok=False)

    def test_renamed_dwg_is_not_treated_as_dxf(self):
        dwg = self.root / 'plan.dwg'
        dwg.write_bytes(b'AC1032 invalid sample')
        self.run_cad('inspect', dwg, ok=False)

    @unittest.skipUnless(os.environ.get('TAKEOFF_TEST_ODA') == '1', 'Enable with a configured ODA runtime')
    def test_actual_dwg_roundtrip_preserves_known_area(self):
        self.doc.saveas(self.file)
        dwg_dir = self.root / 'dwg'
        dwg_dir.mkdir()
        executable = shutil.which('ODAFileConverter')
        self.assertIsNotNone(executable)
        result = subprocess.run([executable, str(self.root), str(dwg_dir), 'ACAD2018', 'DWG', '0', '0', 'source.dxf'],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / 'roundtrip.dxf'
        record = self.run_cad('convert', dwg_dir / 'source.dwg', '--output', output, '--timeout', '30')
        self.assertTrue(record['converter_identity']['sha256'])
        self.assertIn('stderr', record['logs'])
        self.assertFalse(record['audit_repair'])
        loaded = ezdxf.readfile(output)
        handle = next(iter(loaded.modelspace().query('LWPOLYLINE'))).dxf.handle
        measured = self.run_cad('extract', output, '--handles', handle, '--units', 'in',
                                 '--basis', '120 by 144 inch known synthetic fixture')
        self.assertAlmostEqual(measured['entities'][0]['area_sf'], 120)

    def test_annotation_preserves_source_and_uses_same_geometry(self):
        record = self.extract()
        manifest = self.root / 'measure.json'
        manifest.write_text(json.dumps(record))
        output = self.root / 'marked.dxf'
        before = self.file.read_bytes()
        self.run_cad('annotate', self.file, '--manifest', manifest, '--output', output)
        self.assertEqual(before, self.file.read_bytes())
        loaded = ezdxf.readfile(output)
        marks = list(loaded.modelspace().query('LWPOLYLINE[layer=="TAKEOFF_GEOMETRY"]'))
        self.assertEqual(len(marks), 1)
        self.assertEqual(list(marks[0].get_points('xy')), [(0, 0), (120, 0), (120, 144), (0, 144)])


if __name__ == '__main__':
    unittest.main()
