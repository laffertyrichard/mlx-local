#!/usr/bin/env python3
"""Validate simple polygons and calculate signed takeoff areas; no third-party dependencies.
Usage: python geometry.py manifest.json > measured.json
This validates arithmetic, not plan interpretation or polygon-set topology.
"""
import json
import math
import sys
from copy import deepcopy

def number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)

def cross(a, b, c):
    return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])

def signed_area(points):
    # Local origin reduces cancellation for large translated coordinates.
    origin = points[0]
    return sum(cross(origin, points[i], points[i+1]) for i in range(1, len(points)-1))/2

def intersects(a,b,c,d):
    # Exact comparisons are appropriate for the stored finite coordinates.
    def on(p,q,r):
        return cross(p,q,r)==0 and min(p[0],q[0])<=r[0]<=max(p[0],q[0]) and min(p[1],q[1])<=r[1]<=max(p[1],q[1])
    ab_c, ab_d, cd_a, cd_b = cross(a,b,c),cross(a,b,d),cross(c,d,a),cross(c,d,b)
    return ((ab_c>0)!=(ab_d>0) and (cd_a>0)!=(cd_b>0) and all(x!=0 for x in [ab_c,ab_d,cd_a,cd_b])) or on(a,b,c) or on(a,b,d) or on(c,d,a) or on(c,d,b)

def validate_polygon(points):
    if not isinstance(points,list) or len(points)<3:
        raise ValueError('Polygon needs at least 3 vertices')
    if any(not isinstance(p,(list,tuple)) or len(p)!=2 or not all(number(v) for v in p) for p in points):
        raise ValueError('Coordinates must be finite numbers')
    if len(set(map(tuple,points)))!=len(points):
        raise ValueError('Repeated vertex: omit duplicated closing vertex')
    size=len(points)
    for i in range(size):
        a,b=points[i],points[(i+1)%size]
        for j in range(i+1,size):
            if j==i+1 or (i==0 and j==size-1):
                continue
            if intersects(a,b,points[j],points[(j+1)%size]):
                raise ValueError('Non-adjacent polygon edges intersect')
    # Reject adjacent edges that backtrack over each other.
    for i in range(size):
        a,b,c=points[i-1],points[i],points[(i+1)%size]
        if cross(a,b,c)==0 and (a[0]-b[0])*(c[0]-b[0])+(a[1]-b[1])*(c[1]-b[1])>0:
            raise ValueError('Adjacent polygon edges backtrack')
    if abs(signed_area(points))==0:
        raise ValueError('Degenerate polygon')

def measure(data):
    result=deepcopy(data)
    scale=result.get('scale')
    if not number(scale) or scale<=0:
        raise ValueError('scale must be positive coordinate units per real-world length unit')
    zones=result.get('zones',[]); polys=result.get('polys',[])
    if not zones or not polys:
        raise ValueError('Nonempty zones and polys are required')
    by_zone={}
    for z in zones:
        key=z.get('id')
        if not isinstance(key,str) or not key or key in by_zone:
            raise ValueError('Zones need unique nonempty string IDs')
        z.update(gross=0.0,deduct=0.0,net=0.0)
        by_zone[key]=z
    ids=set()
    used=set()
    for p in polys:
        key=p.get('id')
        if not isinstance(key,str) or not key or key in ids:
            raise ValueError('Polygons need unique nonempty string IDs')
        ids.add(key)
        zone=p.get('zone')
        if zone not in by_zone:
            raise ValueError('Polygon has unknown zone')
        if isinstance(p.get('sign'),bool) or p.get('sign') not in [1,-1]:
            raise ValueError('Polygon sign must be +1 or -1')
        validate_polygon(p.get('pts'))
        p['area']=abs(signed_area(p['pts']))/scale**2
        p['signed_area']=p['sign']*p['area']
        by_zone[zone]['gross' if p['sign']==1 else 'deduct']+=p['area']
        used.add(zone)
    for z in zones:
        if z['id'] not in used: raise ValueError('Zone has no measured polygons')
        z['net']=z['gross']-z['deduct']
        if z['net']<0: raise ValueError('Deductions exceed gross area')
    result['net']=sum(z['net'] for z in zones)
    result['validation']={'checked':['finite coordinates','simple nondegenerate polygons','IDs and signs','signed area arithmetic'],
        'not_checked':['source identity and scale calibration','correspondence to plan boundaries','containment and intersections between polygons','scope and material assumptions','overlay or workbook fidelity']}
    return result

if __name__=='__main__':
    try:
        if len(sys.argv)!=2: raise ValueError('Usage: geometry.py manifest.json')
        with open(sys.argv[1]) as source: result=measure(json.load(source))
        json.dump(result,sys.stdout,indent=2,allow_nan=False)
        print()
    except (ValueError,KeyError,TypeError,OSError) as error:
        print('Measurement failed: '+str(error),file=sys.stderr)
        sys.exit(1)
