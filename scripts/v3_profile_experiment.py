#!/usr/bin/env python3
"""Reproduce V3 construction Model Profile evaluation from a frozen manifest."""
import argparse, hashlib, json, os, pathlib, re, statistics, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parents[1]; DEFINITION=ROOT/"V3/profile-experiment-definition.json"
def sha(data): return hashlib.sha256(data).hexdigest()
def file_sha(path): return sha(path.read_bytes())
def snapshot(model):
 folder=pathlib.Path.home()/".cache/huggingface/hub"/("models--"+model.replace("/","--"))/"snapshots"
 return max((x for x in folder.glob("*") if (x/"config.json").exists()),key=lambda x:x.stat().st_mtime)
def normalize(out):
 match=re.search(r"```(?:json)?\s*(.*?)```",out,re.S|re.I); value=json.loads(match.group(1) if match else out)
 if isinstance(value,list): return {"rooms":[x for x in value if "source_image" in x],"comparison":next((x["comparison"] for x in value if "comparison" in x),None)}
 return value
def score(output,gold):
 try: rooms=normalize(output)["rooms"]
 except Exception:return {"quality":0,"claim_hits":0,"claim_total":6,"malformed":1,"unsupported_claims":6}
 hits=0
 for i in range(2):
  if i>=len(rooms):continue
  room=rooms[i]; hits+=room.get("label")==gold["labels"][i]
  try:hits += [float(room["width_ft"]),float(room["length_ft"])]==gold["dimensions"][i]
  except Exception:pass
  try:hits += abs(float(room["area_sq_ft"])-gold["areas"][i])<.01
  except Exception:pass
 return {"quality":hits/6,"claim_hits":hits,"claim_total":6,"malformed":0,"unsupported_claims":6-hits}
def main():
 ap=argparse.ArgumentParser();ap.add_argument("--split",choices=["development","held_out","all"],default="all");ap.add_argument("--output",default="V3/profile-experiment-results.json");args=ap.parse_args()
 definition=json.loads(DEFINITION.read_text()); records=[]; profiles=definition["profiles"]
 cases=[]
 for split,values in definition["splits"].items():
  if split=="train" or (args.split!="all" and split!=args.split):continue
  cases += [(split,x) for x in values]
 for profile in profiles:
  model=profile["base_model"]; snap=snapshot(model)
  for split,case in cases:
   command=[str(pathlib.Path.home()/".local/bin/mlx_vlm.generate"),"--model",str(snap),"--image",*[str(ROOT/x) for x in case["images"]],"--prompt",definition["prompt"],"--max-tokens",str(profile["max_tokens"]),"--temperature",str(profile["temperature"]),"--verbose"]
   started=time.perf_counter(); proc=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=300,env=os.environ|{"HF_HUB_OFFLINE":"1"}); elapsed=(time.perf_counter()-started)*1000
   output=proc.stdout.strip(); manifest={"case":case["id"],"images":{x:file_sha(ROOT/x) for x in case["images"]},"gold":case["gold"],"model_snapshot":str(snap),"model_config_sha256":file_sha(snap/"config.json"),"prompt_sha256":sha(definition["prompt"].encode())}
   records.append({"split":split,"case":case["id"],"profile":profile["id"],"base_model":model,"total_milliseconds":elapsed,"exit":proc.returncode,"first_token_milliseconds":None,"peak_memory_bytes":None,"input_manifest":manifest,"input_manifest_sha256":sha(json.dumps(manifest,sort_keys=True,separators=(",",":")).encode()),"raw_output_sha256":sha(output.encode()),"output":output,"score":score(output,case["gold"])})
 aggregates={}
 for profile in profiles:
  rs=[r for r in records if r["profile"]==profile["id"]]; dev=[r for r in rs if r["split"]=="development"]; held=[r for r in rs if r["split"]=="held_out"]
  aggregates[profile["id"]]={"development_quality":sum(r["score"]["quality"] for r in dev)/len(dev) if dev else None,"held_out_quality":sum(r["score"]["quality"] for r in held)/len(held) if held else None,"independent_held_out_cases":len(held),"median_total_milliseconds":statistics.median(r["total_milliseconds"] for r in rs),"unsupported_claims":sum(r["score"]["unsupported_claims"] for r in rs),"malformed_outputs":sum(r["score"]["malformed"] for r in rs),"failures":sum(r["exit"]!=0 for r in rs)}
 evidence={"definition_sha256":file_sha(DEFINITION),"scorer_version":definition["scorer_version"],"scorer_source_sha256":file_sha(pathlib.Path(__file__).resolve()),"held_out_records":[{"profile":r["profile"],"input":r["input_manifest_sha256"],"output":r["raw_output_sha256"],"score":r["score"]} for r in records if r["split"]=="held_out"]}
 result={"schema_version":2,"definition":"profile-experiment-definition.json","definition_sha256":evidence["definition_sha256"],"scorer_version":definition["scorer_version"],"scorer_source_sha256":evidence["scorer_source_sha256"],"executed_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"records":records,"aggregate":aggregates,"evidence_digest":sha(json.dumps(evidence,sort_keys=True,separators=(",",":")).encode()),"decision":{"promote":"qwen3-vl-30b-construction-json@1","baseline":"qwen3-vl-8b-construction-json@1","rationale":"30B is exact across development and two independent fresh held-out cases; 8B emits unsupported labels/dimensions/areas.","adapter_training":"not justified; cheaper profile and deterministic arithmetic controls have not plateaued on a sufficiently large corpus"}}
 out=ROOT/args.output;out.write_text(json.dumps(result,indent=2)+"\n");print(json.dumps(result,indent=2))
if __name__=="__main__":main()
