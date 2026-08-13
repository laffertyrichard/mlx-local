#!/usr/bin/env python3
"""Loopback-only, token-authenticated HTTP workflow spike."""
import argparse, hashlib, json, os, pathlib, stat
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=pathlib.Path(os.environ.get("MLX_MENU_WORKFLOW_ROOT", ".")).resolve(); TOKEN=os.environ.get("MLX_MENU_WORKFLOW_TOKEN","")
def inspect(paths):
    if not isinstance(paths,list) or len(paths)>64: raise ValueError("paths must contain at most 64 items")
    records=[]; aggregate=0
    for raw in paths:
        path=pathlib.Path(raw).resolve()
        try: path.relative_to(ROOT)
        except ValueError: raise PermissionError(f"read denied outside scope: {path}")
        fd=os.open(path,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode): raise ValueError(f"not a regular file: {path}")
            if info.st_size>64*1024*1024: raise ValueError(f"file exceeds 64 MiB: {path}")
            aggregate+=info.st_size
            if aggregate>256*1024*1024: raise ValueError("aggregate input exceeds 256 MiB")
            data=b""
            while len(data)<info.st_size:
                chunk=os.read(fd,min(1024*1024,info.st_size-len(data)))
                if not chunk:break
                data+=chunk
        finally: os.close(fd)
        records.append({"name":path.name,"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()})
    return {"files":records,"manifest_digest":hashlib.sha256(json.dumps(records,sort_keys=True).encode()).hexdigest(),"provenance":{"executor":"http-loopback","network":"loopback","root":str(ROOT)}}
class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*args): pass
    def sendj(self,status,payload):
        data=json.dumps(payload,separators=(",",":")).encode(); self.send_response(status); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self): self.sendj(200,{"status":"ok"}) if self.path=="/health" else self.sendj(404,{"error":"not_found"})
    def do_POST(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}" or not TOKEN: return self.sendj(401,{"error":"unauthorized"})
        if self.path!="/v3/workflows/construction.inspect-local-artifacts@1.0.0": return self.sendj(404,{"error":"not_found"})
        try:
            n=int(self.headers.get("Content-Length","0"))
            if n<0 or n>1024*1024: return self.sendj(413,{"error":"body_too_large"})
            body=json.loads(self.rfile.read(n)); self.sendj(200,inspect(body.get("paths",[])))
        except PermissionError as exc: self.sendj(403,{"error":"read_denied","detail":str(exc)})
        except Exception as exc: self.sendj(400,{"error":"invalid_request","detail":str(exc)})
if __name__=="__main__":
    ap=argparse.ArgumentParser(); ap.add_argument("--port",type=int,default=18787); args=ap.parse_args(); ThreadingHTTPServer(("127.0.0.1",args.port),H).serve_forever()
