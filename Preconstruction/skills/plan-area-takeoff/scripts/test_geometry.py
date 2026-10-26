"""Analytic cases for measurement math and malformed geometry."""
import unittest
from geometry import measure, signed_area

def rectangle(x,y,w,h): return [[x,y],[x+w,y],[x+w,y+h],[x,y+h]]
def manifest():
 return {'scale':18,'zones':[{'id':'W1','name':'Room','finish':'wood'}],
         'polys':[{'id':'G1','zone':'W1','sign':1,'pts':rectangle(100,100,216,180)},
                  {'id':'D1','zone':'W1','sign':-1,'pts':rectangle(154,154,36,54)}]}
class GeometryTests(unittest.TestCase):
 def test_room_less_island(self):
  r=measure(manifest());self.assertEqual(r['zones'][0]['gross'],120);self.assertEqual(r['zones'][0]['deduct'],6);self.assertEqual(r['net'],114)
 def test_orientation_translation(self):
  self.assertEqual(abs(signed_area(rectangle(1e6,2e6,216,180))),38880)
  self.assertEqual(signed_area(list(reversed(rectangle(0,0,10,5)))),-50)
 def test_concave(self):
  self.assertEqual(abs(signed_area([[0,0],[6,0],[6,2],[2,2],[2,6],[0,6]])),20)
 def test_scale_area_square(self):
  d=manifest();d['scale']=9;self.assertEqual(measure(d)['net'],456)
 def test_bad_scale(self):
  for value in [0,-18,float('nan'),True]:
   d=manifest();d['scale']=value
   with self.assertRaises(ValueError):measure(d)
 def test_self_crossing(self):
  d=manifest();d['polys'][0]['pts']=[[0,0],[5,5],[0,5],[5,0]]
  with self.assertRaises(ValueError):measure(d)
 def test_duplicate_id(self):
  d=manifest();d['polys'].append(d['polys'][0])
  with self.assertRaises(ValueError):measure(d)
 def test_unknown_zone(self):
  d=manifest();d['polys'][0]['zone']='missing'
  with self.assertRaises(ValueError):measure(d)
 def test_nonfinite(self):
  d=manifest();d['polys'][0]['pts'][0][0]=float('inf')
  with self.assertRaises(ValueError):measure(d)
 def test_negative_net(self):
  d=manifest();d['polys'][1]['pts']=rectangle(0,0,500,500)
  with self.assertRaises(ValueError):measure(d)
if __name__=='__main__':unittest.main()
