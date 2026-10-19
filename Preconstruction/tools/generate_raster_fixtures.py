#!/usr/bin/env python3
"""Optional synthetic derivatives using an already-installed PyMuPDF; no installs/models."""
from pathlib import Path
import hashlib,json
import fitz
P=Path(__file__).resolve().parents[1];F=P/'fixtures';src=F/'synthetic-plan.pdf'
def main():
 doc=fitz.open(src);pix=doc[0].get_pixmap(matrix=fitz.Matrix(2,2));pix.save(str(F/'synthetic-scan.png'))
 scan=fitz.open();page=scan.new_page(width=612,height=792);page.insert_image(page.rect,pixmap=pix)
 target=F/'synthetic-scan.pdf'
 if target.exists():target.unlink()  # Named synthetic fixture only.
 scan.save(target)
 doc[0].get_pixmap(matrix=fitz.Matrix(2,2),clip=fitz.Rect(100,200,316,380)).save(str(F/'synthetic-crop.png'))
 (F/'derived-fixtures.json').write_text(json.dumps({'synthetic':True,'parent':'synthetic-plan.pdf','parent_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'generator':'PyMuPDF '+fitz.VersionBind,'derived':[{'path':'synthetic-scan.png','frame_id':'SCAN01','pixel_size':[1224,1584],'parent_to_child_affine':[2,0,0,2,0,0]},{'path':'synthetic-scan.pdf','frame_id':'SCANPDF01','page_size_points':[612,792],'parent_to_child_affine':[1,0,0,1,0,0],'text_extractable':False},{'path':'synthetic-crop.png','frame_id':'CROP01','pixel_size':[432,360],'crop_pdf_points':[100,200,316,380],'parent_to_child_affine':[2,0,0,2,-200,-400]}],'limits':'Synthetic rendered fixtures only; no OCR/VLM inference performed.'},indent=2)+'\n')
 print('Synthetic raster derivatives regenerated; refresh package checksum inventory after intentional changes.')
if __name__=='__main__':main()
