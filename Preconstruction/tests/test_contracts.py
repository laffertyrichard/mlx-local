#!/usr/bin/env python3
"""Lightweight package/fixture boundary checks, NOT application acceptance."""
import copy,hashlib,importlib.util,json,math,re,unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('area',P/'skills/plan-area-takeoff/scripts/geometry.py')
area=importlib.util.module_from_spec(spec);spec.loader.exec_module(area)
def load(name):return json.loads((P/'fixtures'/name).read_text())
class PackageContracts(unittest.TestCase):
 def test_signed_area_against_independent_dimensions(self):
  result=area.measure(load('area-plane.json'));expected=load('expected.json')
  self.assertEqual(result['zones'][0]['gross'],12*10)
  self.assertEqual(result['zones'][0]['deduct'],2*3)
  self.assertEqual(result['net'],expected['net_candidate_sf'])
  self.assertEqual(result['net'],114)
 def test_open_route_and_repeated_physical_item(self):
  g=load('extra-geometry.json');r=g['routes'][0];pts=r['pts']
  length=sum(math.dist(a,b) for a,b in zip(pts,pts[1:]))/g['scale']
  self.assertFalse(r['closed']);self.assertEqual(length,22)
  self.assertEqual(len(g['counts']),3)
  self.assertEqual(len({c['physical_item_id'] for c in g['counts']}),2)
 def test_fixture_source_bytes_and_cross_references(self):
  r=load('revision.json');ids={s['id'] for s in r['sources']}
  for s in r['sources']:
   self.assertEqual(hashlib.sha256((P/'fixtures'/s['path']).read_bytes()).hexdigest(),s['sha256'])
  qids={q['id'] for q in r['quantities']};issues={q['id'] for q in r['questions']}
  for q in r['quantities']:
   self.assertTrue(set(q['source_ids'])<=ids);self.assertTrue(set(q['question_ids'])<=issues)
  for issue in r['questions']+r['unfinished_measurements']:
   self.assertTrue(set(issue['quantity_ids'])<=qids)
 def test_unknown_retained_conflict_and_pending_release_preserved(self):
  r=load('revision.json');qs={q['id']:q for q in r['quantities']}
  self.assertIsNone(qs['QTY03']['value']);self.assertIsNone(qs['QTY04']['value'])
  self.assertEqual(qs['QTY02']['scope_state'],'existing_retained')
  self.assertTrue(all(not q['installed_total_eligible'] for q in qs.values()))
  self.assertTrue(any(q['id']=='Q01' and q['status']=='open' for q in r['questions']))
  self.assertTrue(any(q['id']=='U01' for q in r['unfinished_measurements']))
  self.assertTrue(all(a['status']=='pending' and a['actor'] is None for a in r['approvals']))
 def test_witness_dimensions_agree_and_adversarial_conflict_does_not(self):
  checks=load('revision.json')['calibrations'][0]['checks']
  self.assertEqual({c['coordinate_length']/c['real_length'] for c in checks},{18})
  conflict=next(c for c in load('adversarial-cases.json')['cases'] if c['id']=='calibration_conflict')
  self.assertEqual({c['coordinate_length']/c['real_length'] for c in conflict['checks']},{18,20})
 def test_crop_landmarks_forward_inverse(self):
  f=load('extra-geometry.json')['derived_frame_example'];a,b,c,d,e,h=f['parent_to_child_affine']
  def forward(x,y):return a*x+c*y+e,b*x+d*y+h
  self.assertEqual(forward(100,200),(0,0));self.assertEqual(forward(316,380),(432,360))
  det=a*d-b*c;self.assertNotEqual(det,0)
  x,y=forward(154,254);self.assertEqual(((d*(x-e)-c*(y-h))/det,(-b*(x-e)+a*(y-h))/det),(154,254))
 def test_area_helper_explicitly_does_not_claim_topology(self):
  result=area.measure(load('area-plane.json'))
  self.assertIn('containment and intersections between polygons',result['validation']['not_checked'])
  data=load('area-plane.json');data['polys'][1]['pts']=[[50,200],[86,200],[86,254],[50,254]]
  # Equal-area deduction outside gross remains arithmetic-valid: a production topology gate is still needed.
  self.assertEqual(area.measure(data)['net'],114)
 def test_area_helper_rejects_invalid_data(self):
  for name,change in [('nan',lambda d:d.update(scale=float('nan'))),('zero_scale',lambda d:d.update(scale=0)),('bool_sign',lambda d:d['polys'][0].update(sign=True)),('bow_tie',lambda d:d['polys'][0].update(pts=[[0,0],[10,10],[0,10],[10,0]]))]:
   d=copy.deepcopy(load('area-plane.json'));change(d)
   with self.subTest(name=name),self.assertRaises(ValueError):area.measure(d)
 def test_scope_examples_are_plain_text_bounded_and_disclose_unknowns(self):
  for name in ['scope-client-draft.txt','scope-internal-draft.txt']:
   text=(P/'fixtures'/name).read_text();self.assertLessEqual(len(text),4000)
   self.assertTrue(text.isascii());self.assertNotRegex(text,r'\*|^#|^\d+\.',)
  client=(P/'fixtures/scope-client-draft.txt').read_text()
  for item in ['114 SF','6 SF','40 SF','Q01','Q02','U01','pending']:
   self.assertIn(item,client)
 def test_schema_and_fixture_separate_from_original_template(self):
  schema=json.loads((P/'schemas/revision.schema.json').read_text())
  self.assertEqual(schema['$schema'],'https://json-schema.org/draft/2020-12/schema')
  template=json.loads((P/'templates/project/measurements/project-manifest.json').read_text())
  self.assertEqual(template['plane_manifests'],[]);self.assertEqual(template['quantities'],[])
  self.assertEqual(load('revision.json')['schema_version'],'0.1')
if __name__=='__main__':unittest.main(verbosity=2)
