#!/usr/bin/env python3
"""Optional fixture checks with existing jsonschema/Shapely/PyMuPDF only.
Not app acceptance and not proof that the area helper implements Boolean topology.
"""
import hashlib,json,unittest
from pathlib import Path
import fitz,jsonschema
from shapely.geometry import Polygon
P=Path(__file__).resolve().parents[1];F=P/'fixtures'
class OptionalFixtureChecks(unittest.TestCase):
 def test_proposed_schema_instance(self):
  schema=json.loads((P/'schemas/revision.schema.json').read_text())
  jsonschema.Draft202012Validator.check_schema(schema)
  jsonschema.validate(json.loads((F/'revision.json').read_text()),schema)
 def test_boolean_net_mask_independent_of_signed_sum(self):
  data=json.loads((F/'area-plane.json').read_text());g=Polygon(data['polys'][0]['pts']);d=Polygon(data['polys'][1]['pts'])
  self.assertTrue(g.covers(d));net=g.difference(d)
  self.assertEqual(net.area/data['scale']**2,114)
  self.assertEqual(len(net.interiors),1)
 def test_invalid_topology_fixtures_are_actually_invalid(self):
  data=json.loads((F/'adversarial-cases.json').read_text())['cases']
  overlap=next(x for x in data if x['id']=='overlap');a,b=map(Polygon,overlap['polys'])
  self.assertEqual(a.intersection(b).area,50)
  protruding=next(x for x in data if x['id']=='protruding_deduction')
  self.assertFalse(Polygon(protruding['gross']).covers(Polygon(protruding['deduction'])))
 def test_pdf_scan_crop_source_frames(self):
  vector=fitz.open(F/'synthetic-plan.pdf');scan=fitz.open(F/'synthetic-scan.pdf')
  self.assertEqual(len(vector),1);self.assertIn('12 ft',vector[0].get_text());self.assertFalse(scan[0].get_text().strip())
  crop=fitz.Pixmap(F/'synthetic-crop.png');self.assertEqual((crop.width,crop.height),(432,360))
  metadata=json.loads((F/'derived-fixtures.json').read_text())
  self.assertEqual(metadata['parent_sha256'],hashlib.sha256((F/metadata['parent']).read_bytes()).hexdigest())
 def test_rendered_svg_net_fill_hole_is_clear(self):
  doc=fitz.open(F/'synthetic-overlay.svg');pix=doc[0].get_pixmap(colorspace=fitz.csRGB,alpha=False)
  def rgb(x,y):return tuple(pix.pixel(x,y))
  self.assertEqual(rgb(170,280),(255,255,255))
  self.assertNotEqual(rgb(220,330),(255,255,255))
if __name__=='__main__':unittest.main(verbosity=2)
