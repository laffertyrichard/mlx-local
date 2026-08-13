#!/usr/bin/env python3
"""Run the winning hybrid tracer: typed MCP workflow + direct local MLX runtime."""
import argparse, json, os, pathlib, subprocess, sys, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
def call(proc,rid,method,params):
 proc.stdin.write(json.dumps({"jsonrpc":"2.0","id":rid,"method":method,"params":params})+"\n"); proc.stdin.flush(); return json.loads(proc.stdout.readline())
def main():
 ap=argparse.ArgumentParser(); ap.add_argument("--reuse-tracer-result",action="store_true"); ap.add_argument("--output",default="V3/construction-tracer-result.json"); args=ap.parse_args()
 images=[ROOT/"V3/fixtures/heldout-e.png",ROOT/"V3/fixtures/heldout-f.png"]; output=ROOT/args.output
 env=os.environ|{"MLX_MENU_WORKFLOW_ROOT":str(ROOT/"V3/fixtures")}
 mcp=subprocess.Popen([sys.executable,str(ROOT/"scripts/v3_mcp_server.py")],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
 started=time.perf_counter()
 try:
  init=call(mcp,1,"initialize",{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"construction-tracer","version":"1"}})
  inspection=call(mcp,2,"tools/call",{"name":"construction_inspect_local_artifacts","arguments":{"paths":[str(x) for x in images]}})
  model_list=call(mcp,3,"tools/call",{"name":"local_model_list","arguments":{}})
  mcp_ms=(time.perf_counter()-started)*1000
  if not args.reuse_tracer_result:
   subprocess.run(["swift","run","-c","release","ConstructionTracer",*[str(x) for x in images],str(output)],cwd=ROOT,check=True)
  report=json.loads(output.read_text()); report["hybrid_boundary_evidence"]={"mcp_initialize":init["result"]["serverInfo"],"workflow":inspection["result"]["structuredContent"],"model_control":model_list["result"]["structuredContent"],"mcp_elapsed_ms":mcp_ms,"inference_transport":"direct loopback HTTP worker managed by LocalInferenceBackends","no_cloud_fallback":True}
  report["accepted"]=bool(report.get("accepted") and len(report["hybrid_boundary_evidence"]["workflow"]["files"])==2 and report["hybrid_boundary_evidence"]["model_control"]["model_count"]>0)
  output.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n"); print(json.dumps(report,indent=2))
  if not report["accepted"]: raise SystemExit(1)
 finally:
  mcp.terminate()
  try:mcp.wait(timeout=2)
  except subprocess.TimeoutExpired:mcp.kill()
if __name__=="__main__":main()
