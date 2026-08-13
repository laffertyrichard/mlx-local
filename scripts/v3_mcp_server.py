#!/usr/bin/env python3
"""Minimal, permissioned MCP stdio spike for V3 boundary measurements."""
import hashlib, json, os, pathlib, stat, sys, urllib.request
ROOT = pathlib.Path(os.environ.get("MLX_MENU_WORKFLOW_ROOT", ".")).resolve()

def inspect_files(arguments):
    requested=arguments.get("paths", [])
    if not isinstance(requested,list) or len(requested)>64: raise ValueError("paths must be an array of at most 64 items")
    records=[]; aggregate=0
    for raw in requested:
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
            chunks=[]; remaining=info.st_size
            while remaining:
                chunk=os.read(fd,min(1024*1024,remaining))
                if not chunk: raise OSError(f"short read: {path}")
                chunks.append(chunk); remaining-=len(chunk)
            data=b"".join(chunks)
        finally: os.close(fd)
        records.append({"name":path.name,"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()})
    payload={"files":records,"provenance":{"executor":"mcp-local","network":"none","root":str(ROOT)}}
    payload["manifest_digest"]=hashlib.sha256(json.dumps(records,sort_keys=True).encode()).hexdigest()
    return payload

def response(req):
    rid=req.get("id"); method=req.get("method")
    if method=="initialize": result={"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"mlx-menu-v3-spike","version":"0.1.0"}}
    elif method=="notifications/initialized": return None
    elif method=="tools/list": result={"tools":[{"name":"construction_inspect_local_artifacts","description":"Hash explicitly scoped local files. No network/process access.","inputSchema":{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"}}},"required":["paths"]}},{"name":"local_model_list","description":"List models through the fixed loopback MLX V1 endpoint.","inputSchema":{"type":"object","properties":{},"additionalProperties":False}}]}
    elif method=="tools/call":
        params=req.get("params",{})
        if params.get("name")=="construction_inspect_local_artifacts": payload=inspect_files(params.get("arguments",{}))
        elif params.get("name")=="local_model_list":
            with urllib.request.urlopen("http://127.0.0.1:8081/v1/models",timeout=5) as remote: raw=json.load(remote)
            payload={"model_count":len(raw.get("data",[])),"provenance":{"executor":"mcp-loopback-proxy","endpoint":"127.0.0.1:8081/v1/models"}}
        else: raise ValueError("unknown tool")
        result={"content":[{"type":"text","text":json.dumps(payload,separators=(",",":"))}],"structuredContent":payload}
    else: raise ValueError(f"unsupported method: {method}")
    return {"jsonrpc":"2.0","id":rid,"result":result}

for line in sys.stdin:
    try:
        if len(line.encode()) > 1024 * 1024: raise ValueError("MCP frame exceeds 1 MiB")
        req=json.loads(line); out=response(req)
        if out is not None: print(json.dumps(out,separators=(",",":")),flush=True)
    except Exception as exc:
        print(json.dumps({"jsonrpc":"2.0","id":req.get("id") if "req" in locals() else None,"error":{"code":-32001,"message":str(exc),"data":{"type":type(exc).__name__}}},separators=(",",":")),flush=True)
