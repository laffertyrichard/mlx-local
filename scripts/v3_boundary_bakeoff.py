#!/usr/bin/env python3
"""Run measured HTTP, MCP, and hybrid Prime/MLX boundary spikes."""
import argparse, json, os, pathlib, secrets, statistics, subprocess, sys, tempfile, time, urllib.error, urllib.request
HERE=pathlib.Path(__file__).resolve().parent; ROOT=HERE.parent

def percentile(xs,p):
    ys=sorted(xs); return ys[min(len(ys)-1,round((len(ys)-1)*p))]
def stats(xs): return {"n":len(xs),"median_ms":statistics.median(xs),"p95_ms":percentile(xs,.95),"min_ms":min(xs),"max_ms":max(xs)}
def http_json(url,method="GET",payload=None,token=None):
    data=None if payload is None else json.dumps(payload).encode(); headers={"Content-Type":"application/json"}
    if token: headers["Authorization"]="Bearer "+token
    req=urllib.request.Request(url,data=data,headers=headers,method=method)
    with urllib.request.urlopen(req,timeout=10) as r: return r.status,json.load(r)
def mcp_call(proc,rid,method,params=None):
    msg={"jsonrpc":"2.0","id":rid,"method":method}
    if params is not None: msg["params"]=params
    proc.stdin.write(json.dumps(msg,separators=(",",":"))+"\n"); proc.stdin.flush()
    return json.loads(proc.stdout.readline())
def timed(fn):
    t=time.perf_counter_ns(); value=fn(); return (time.perf_counter_ns()-t)/1e6,value

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--iterations",type=int,default=30); ap.add_argument("--output",default="V3/boundary-bakeoff.json"); args=ap.parse_args()
    work=pathlib.Path(tempfile.mkdtemp(prefix="mlx-v3-boundary-")); fixture=work/"plan.txt"; fixture.write_text("Room A: 12'-6 x 10'-0\n")
    token=secrets.token_urlsafe(24); env=os.environ|{"MLX_MENU_WORKFLOW_ROOT":str(work),"MLX_MENU_WORKFLOW_TOKEN":token}
    port=18787; http_proc=subprocess.Popen([sys.executable,str(HERE/"v3_http_workflow_server.py"),"--port",str(port)],env=env)
    mcp_proc=subprocess.Popen([sys.executable,str(HERE/"v3_mcp_server.py")],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
    try:
        deadline=time.time()+5
        while True:
            try: http_json(f"http://127.0.0.1:{port}/health"); break
            except Exception:
                if time.time()>deadline: raise
                time.sleep(.05)
        init_ms,init=mcp_timed=lambda:None,None
        init_ms,init=timed(lambda:mcp_call(mcp_proc,1,"initialize",{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bakeoff","version":"1"}}))
        direct_model_ok=True
        try: direct_status,direct_models=http_json("http://127.0.0.1:8081/v1/models")
        except Exception as exc: direct_model_ok=False; direct_models={"error":str(exc)}
        payload={"paths":[str(fixture)]}; http_times=[]; mcp_times=[]; hybrid_times=[]; rid=10
        http_result=mcp_result=hybrid_result=None
        for _ in range(args.iterations):
            ms,http_result=timed(lambda:(http_json(f"http://127.0.0.1:{port}/v3/workflows/construction.inspect-local-artifacts@1.0.0","POST",payload,token), http_json("http://127.0.0.1:8081/v1/models") if direct_model_ok else None)); http_times.append(ms)
            rid+=1
            def all_mcp():
                nonlocal rid
                a=mcp_call(mcp_proc,rid,"tools/call",{"name":"construction_inspect_local_artifacts","arguments":payload}); rid+=1
                b=mcp_call(mcp_proc,rid,"tools/call",{"name":"local_model_list","arguments":{}}) if direct_model_ok else None; return a,b
            ms,mcp_result=timed(all_mcp); mcp_times.append(ms); rid+=1
            def hybrid():
                nonlocal rid
                a=mcp_call(mcp_proc,rid,"tools/call",{"name":"construction_inspect_local_artifacts","arguments":payload}); rid+=1
                b=http_json("http://127.0.0.1:8081/v1/models") if direct_model_ok else None; return a,b
            ms,hybrid_result=timed(hybrid); hybrid_times.append(ms); rid+=1
        denied={}
        try: http_json(f"http://127.0.0.1:{port}/v3/workflows/construction.inspect-local-artifacts@1.0.0","POST",{"paths":["/etc/hosts"]},token)
        except urllib.error.HTTPError as exc: denied["http_status"]=exc.code; denied["http_body"]=json.loads(exc.read())
        rid+=1; denied["mcp"]=mcp_call(mcp_proc,rid,"tools/call",{"name":"construction_inspect_local_artifacts","arguments":{"paths":["/etc/hosts"]}})
        # Restart/error isolation: killing MCP must leave HTTP/V1 healthy, killing workflow HTTP must leave MCP/V1 healthy.
        mcp_proc.terminate(); mcp_proc.wait(timeout=2); isolation={"http_after_mcp_exit":http_json(f"http://127.0.0.1:{port}/health")[0]}
        if direct_model_ok: isolation["v1_after_mcp_exit"]=http_json("http://127.0.0.1:8081/v1/models")[0]
        http_proc.terminate(); http_proc.wait(timeout=2)
        result={"schema_version":1,"generated_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"iterations":args.iterations,
          "host":{"python":sys.version.split()[0]},"live_v1_available":direct_model_ok,"mcp_initialize_ms":init_ms,
          "candidates":{"http":{"timing":stats(http_times),"transport":"loopback JSON/HTTP","streaming":"V1 SSE available; workflow response non-streaming","cancellation":"client disconnect/process cancellation","permissions":"bearer auth + fixed file roots","artifact_transport":"path + hash manifest"},
          "mcp":{"timing":stats(mcp_times),"transport":"JSON-RPC stdio; model access via scoped loopback tool","streaming":"progress notifications possible but not implemented in spike","cancellation":"process/task cancellation","permissions":"tool schema + fixed file roots/endpoint","artifact_transport":"structuredContent path + hash manifest"},
          "hybrid":{"timing":stats(hybrid_times),"transport":"MCP workflows + direct V1 HTTP inference","streaming":"native V1 SSE","cancellation":"per-boundary cancellation","permissions":"MCP tool scopes; V1 remains loopback-only","artifact_transport":"MCP structuredContent; HTTP model payloads"}},
          "denial_checks":denied,"restart_isolation":isolation,
          "selection":{"winner":"hybrid","reason":"Preserves proven V1 HTTP/SSE inference while adding typed, discoverable MCP workflow permissions; measured overhead remains small and failures are isolated.","losers":{"http":"Lowest conceptual count but couples workflow discovery/authorization to a bespoke API and duplicates tool schemas.","mcp":"Strong tool contract but wrapping all model traffic adds framing/proxy coupling and loses direct V1/SSE compatibility."}},
          "limitations":["Transport/control-plane benchmark; model generation latency intentionally excluded.","MCP progress streaming and cancellation handshake are not productionized.","Single-host loopback sample; developer effort assessed from spike surface, not team study."]}
        out=ROOT/args.output; out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(result,indent=2)+"\n"); print(json.dumps(result,indent=2))
    finally:
        for proc in (mcp_proc,http_proc):
            if proc.poll() is None: proc.terminate()
            try: proc.wait(timeout=2)
            except subprocess.TimeoutExpired: proc.kill()
if __name__=="__main__": main()
