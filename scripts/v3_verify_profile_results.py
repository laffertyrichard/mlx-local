#!/usr/bin/env python3
"""Verify saved V3 profile evidence without rerunning expensive local generation."""
import hashlib,json,pathlib,sys
ROOT=pathlib.Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/"scripts"));import v3_profile_experiment as runner
def sha(data):return hashlib.sha256(data).hexdigest()
def main():
 definition=json.loads(runner.DEFINITION.read_text()); results_path=ROOT/"V3/profile-experiment-results.json"; results=json.loads(results_path.read_text())
 assert results["definition_sha256"]==runner.file_sha(runner.DEFINITION)
 assert results["scorer_source_sha256"]==runner.file_sha(pathlib.Path(runner.__file__).resolve())
 cases={x["id"]:x for values in definition["splits"].values() for x in values}
 for record in results["records"]:
  case=cases[record["case"]]; assert record["raw_output_sha256"]==sha(record["output"].encode())
  assert record["score"]==runner.score(record["output"],case["gold"])
  for path,digest in record["input_manifest"]["images"].items():assert runner.file_sha(ROOT/path)==digest
  assert runner.file_sha(pathlib.Path(record["input_manifest"]["model_snapshot"])/"config.json")==record["input_manifest"]["model_config_sha256"]
 evidence={"definition_sha256":results["definition_sha256"],"scorer_version":results["scorer_version"],"scorer_source_sha256":results["scorer_source_sha256"],"held_out_records":[{"profile":r["profile"],"input":r["input_manifest_sha256"],"output":r["raw_output_sha256"],"score":r["score"]} for r in results["records"] if r["split"]=="held_out"]}
 assert results["evidence_digest"]==sha(json.dumps(evidence,sort_keys=True,separators=(",",":")).encode())
 print(f"verified {len(results['records'])} raw runs, {len(evidence['held_out_records'])//2} independent held-out cases, evidence {results['evidence_digest']}")
if __name__=="__main__":main()
