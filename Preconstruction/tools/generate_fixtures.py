#!/usr/bin/env python3
"""Generate synthetic package examples only; no model extraction or production exporter.
Standard library; overwrite only the named files under the package fixtures directory.
"""
from pathlib import Path
import hashlib,json
P=Path(__file__).resolve().parents[1];F=P/'fixtures'
def dump(name,value):(F/name).write_text(json.dumps(value,indent=2,allow_nan=False)+'\n')
def pdf_bytes():
    # Minimal one-page vector/text PDF; coordinates match the documented top-left frame.
    stream='''0.5 w
100 412 216 180 re S
154 484 36 54 re S
BT /F1 12 Tf 40 740 Td (SYNTHETIC - NOT FOR CONSTRUCTION - A-SYN-1) Tj ET
BT /F1 12 Tf 140 620 Td (12 ft - finished faces) Tj ET
BT /F1 12 Tf 330 500 Td (10 ft) Tj ET
BT /F1 12 Tf 120 560 Td (ROOM ALPHA - NEW FLOOR) Tj ET
BT /F1 10 Tf 155 505 Td (2 x 3 ft) Tj ET
BT /F1 10 Tf 100 390 Td (Fixed island: floor finish excluded) Tj ET
BT /F1 10 Tf 100 370 Td (Dimension basis: 18 PDF points per foot both axes.) Tj ET
BT /F1 10 Tf 100 350 Td (Existing retained floor elsewhere: 40 SF; reference only.) Tj ET
BT /F1 10 Tf 100 330 Td (Tile wall height unestablished. Base run not yet traced.) Tj ET
BT /F1 10 Tf 100 310 Td (R1 wood vs R2 tile selection conflict remains OPEN.) Tj ET
'''.encode('ascii')
    objs=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'endstream']
    out=bytearray(b'%PDF-1.4\n');offsets=[0]
    for i,obj in enumerate(objs,1):offsets.append(len(out));out.extend(f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n')
    start=len(out);out.extend(f'xref\n0 {len(objs)+1}\n0000000000 65535 f \n'.encode())
    for o in offsets[1:]:out.extend(f'{o:010d} 00000 n \n'.encode())
    out.extend(f'trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode());return bytes(out)
def main():
 F.mkdir(exist_ok=True)
 (F/'synthetic-plan.pdf').write_bytes(pdf_bytes())
 head='<svg xmlns="http://www.w3.org/2000/svg" width="612" height="792" viewBox="0 0 612 792"><rect width="612" height="792" fill="white"/>'
 labels='''<g font-family="sans-serif" fill="#111"><text x="30" y="35" font-size="13">SYNTHETIC - NOT FOR CONSTRUCTION</text><text x="100" y="78">12 ft / finished faces</text><text x="330" y="190">10 ft</text><text x="110" y="130">ROOM ALPHA</text><text x="155" y="255" font-size="10">2 x 3 ft</text></g>'''
 outline='<g fill="none" stroke="#111"><rect x="100" y="200" width="216" height="180"/><rect x="154" y="254" width="36" height="54"/></g>'
 (F/'synthetic-plan.svg').write_text(head+labels+outline+'</svg>\n')
 fill='<path d="M100 200H316V380H100Z M154 254H190V308H154Z" fill="#80baba" fill-opacity="0.4" fill-rule="evenodd" stroke="#246060"/>'
 legend='''<g font-family="sans-serif" font-size="12"><text x="60" y="430">G01 - D01: 120 - 6 = 114 SF installed floor candidate</text><text x="60" y="455">D01: fixed island exclusion; fill remains clear</text><text x="60" y="480">Material: unresolved wood/tile revision conflict Q01</text><text x="60" y="505">All geometry source-linked; human review PENDING</text><text x="60" y="530">Illustrative fixture overlay; do not scale this view</text></g>'''
 (F/'synthetic-overlay.svg').write_text(head+fill+labels+outline+legend+'</svg>\n')
 # Area helper schema is deliberately unchanged.
 area={'source':{'file':'synthetic-plan.pdf','sheet':'A-SYN-1','page_index':0,'revision':'SYN-R1'},'coordinate_system':'PDF points; top-left origin; original unrotated page','length_unit':'ft','area_unit':'SF','scale':18,'scale_note':'X:216 points/12 ft; Y:180 points/10 ft; finished-face synthetic checks','scope':'Room Alpha floor candidate only; fixed island excluded; material conflict remains open','zones':[{'id':'Z01','name':'Room Alpha','finish':'UNRESOLVED Q01'}],'polys':[{'id':'G01','zone':'Z01','sign':1,'pts':[[100,200],[316,200],[316,380],[100,380]],'note':'Finished-face gross floor'},{'id':'D01','zone':'Z01','sign':-1,'pts':[[154,254],[190,254],[190,308],[154,308]],'note':'Fixed 2 by 3 ft island deduction'}]}
 dump('area-plane.json',area)
 (F/'synthetic-revision-note.txt').write_text('SYNTHETIC SCHEDULE R2: Room Alpha floor tile; R1 says wood. No precedence or selection answer supplied. Q01 remains open.\n')
 src=[{'id':'S01','path':'synthetic-plan.pdf','sha256':hashlib.sha256((F/'synthetic-plan.pdf').read_bytes()).hexdigest(),'revision':'SYN-R1','role':'proposed','page_index':0,'sheet':'A-SYN-1'},{'id':'S02','path':'synthetic-revision-note.txt','sha256':hashlib.sha256((F/'synthetic-revision-note.txt').read_bytes()).hexdigest(),'revision':'SYN-R2','role':'specification','page_index':0,'sheet':'SYN-SCHEDULE'}]
 def q(i,physical,op,trade,unit,value,state,basis,geom,issues,eligible=False):return {'id':i,'physical_item_id':physical,'operation':op,'trade':trade,'location':'Room Alpha','material':None,'unit':unit,'value':value,'scope_state':state,'basis':basis,'source_ids':['S01'],'geometry_refs':geom,'question_ids':issues,'related_work_ids':[],'relationship':'selected','installed_total_eligible':eligible}
 quantities=[q('QTY01','FLOOR01','install','flooring','SF',114,'provisional','G01 gross minus D01; selected material unresolved Q01',['G01','D01'],['Q01']),q('QTY02','FLOOR-EX','reference','flooring','SF',40,'existing_retained','Explicit synthetic retained reference, not new installation',[],[]),q('QTY03','WALL-TILE01','install','tile','SF',None,'unresolved','Height unestablished; missing design dimension Q02',[],['Q02']),q('QTY04','BASE01','install','trim','LF',None,'unresolved','Depicted base not yet traced; unfinished measurement U01',[],[]),q('QTY05','ROUTE01','install','trim','LF',22,'provisional','Synthetic open route: 12 + 10 ft',['L01'],[]),q('QTY06','FIXTURES','install','electrical','EA',2,'provisional','Synthetic physical items F01/F02; F01 repeated in second view',['C01','C02','C03'],[])]
 rev={'schema_version':'0.1','synthetic':True,'revision_id':'SYN-REV-01','sources':src,'calibrations':[{'id':'CAL01','source_id':'S01','frame_id':'FRAME01','plane_id':'PLAN-FLOOR','coordinate_unit':'pdf_points','length_unit':'ft','scale':18,'status':'candidate','checks':[{'axis':'x','coordinate_length':216,'real_length':12,'datum':'finished-face witness points x100 to x316'},{'axis':'y','coordinate_length':180,'real_length':10,'datum':'finished-face witness points y200 to y380'}]}],'quantities':quantities,'questions':[{'id':'Q01','quantity_ids':['QTY01'],'source_ids':['S01','S02'],'description':'Which floor material governs? R1 wood and R2 tile are conflicting; do not assume newest wins.','status':'open'},{'id':'Q02','quantity_ids':['QTY03'],'source_ids':['S01'],'description':'Supply governing tile wall height; no quantity established.','status':'open'}],'unfinished_measurements':[{'id':'U01','quantity_ids':['QTY04'],'source_ids':['S01'],'description':'Trace depicted base run; this is incomplete measurement, not missing design.','status':'unfinished'}],'checks':[{'id':'CHK-'+d,'dimension':d,'status':'pending','evidence':None} for d in ['arithmetic','topology','visual','scope','artifact']],'approvals':[{'gate':'reviewed_geometry','status':'pending','snapshot_sha256':None,'actor':None,'at':None},{'gate':'scope_release','status':'pending','snapshot_sha256':None,'actor':None,'at':None}]}
 dump('revision.json',rev)
 dump('extra-geometry.json',{'source_id':'S01','frame_id':'FRAME01','plane_id':'PLAN-FLOOR','length_unit':'ft','scale':18,'routes':[{'id':'L01','role':'measured_polyline','pts':[[100,200],[316,200],[316,380]],'closed':False}],'counts':[{'id':'C01','physical_item_id':'F01','view':'plan'},{'id':'C02','physical_item_id':'F02','view':'plan'},{'id':'C03','physical_item_id':'F01','view':'elevation'}],'derived_frame_example':{'parent_frame_id':'FRAME01','child_frame_id':'CROP01','crop_pdf_points':[100,200,316,380],'parent_to_child_affine':[2,0,0,2,-200,-400],'child_width':432,'child_height':360}})
 dump('expected.json',{'gross_sf':120,'deduction_sf':6,'net_candidate_sf':114,'retained_reference_sf':40,'released_new_floor_sf':None,'open_route_lf':22,'deduplicated_ea':2,'release_allowed':False,'reason':'No human calibration/geometry approval; material conflict, unestablished tile and unfinished measurement remain'})
 dump('adversarial-cases.json',{'cases':[{'id':'overlap','status':'topology_must_fail','polys':[[[0,0],[10,0],[10,10],[0,10]],[[5,0],[15,0],[15,10],[5,10]]]},{'id':'protruding_deduction','status':'topology_must_fail','gross':[[0,0],[10,0],[10,10],[0,10]],'deduction':[[8,8],[12,8],[12,12],[8,12]]},{'id':'calibration_conflict','status':'basis_must_hold','checks':[{'axis':'x','coordinate_length':216,'real_length':12},{'axis':'y','coordinate_length':200,'real_length':10}]},{'id':'missing_height','status':'quantity_null','quantity_id':'QTY03'},{'id':'revision_conflict','status':'scope_release_hold','question_id':'Q01'},{'id':'stale_source','status':'resume_must_fail','change':'one source byte or calibration/profile digest'}]})
 (F/'scope-client-draft.txt').write_text('DRAFT - SYNTHETIC FIXTURE - HUMAN REVIEW PENDING\n\nFlooring\n\n-Room Alpha: 114 SF provisional installed floor area, calculated from 120 SF gross less 6 SF fixed-island deduction (QTY01; G01; D01; S01). Material remains unresolved: R1 wood conflicts with R2 tile (Q01; S01; S02).\n\n-Existing retained floor: 40 SF reference only, outside new-install total (QTY02; S01).\n\n-Tile wall quantity is unestablished pending height (Q02; QTY03). Depicted base measurement remains unfinished (U01; QTY04).\n\n-No pricing established. Geometry, material and scope release remain pending. This draft is not procurement or fabrication approval.\n')
 (F/'scope-internal-draft.txt').write_text('INTERNAL NOTES - SYNTHETIC FIXTURE\n\n-Resolve Q01 material authority; no automatic newest-revision precedence.\n\n-Obtain Q02 tile height and complete U01 measurement.\n\n-Related access, protection and restoration extent/responsibility remain unestablished; do not infer quantities.\n\n-No vendor bid costs supplied. No price or markup calculated.\n')
 print('Synthetic fixtures generated; no models invoked.')
if __name__=='__main__':main()
