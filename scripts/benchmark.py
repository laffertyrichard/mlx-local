#!/usr/bin/env python3
"""Repeatable, local-only MLX capability benchmark runner.

Run one cell: scripts/benchmark.py --model ID --capability OCR
Run the complete (expensive) compatible suite: scripts/benchmark.py --model ID --all
"""
from __future__ import annotations
import argparse, json, os, re, subprocess, tempfile, time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASKS = json.loads((ROOT / "Benchmarks/tasks.json").read_text())
PROFILES = json.loads((ROOT / "ModelMetadata/capabilities.json").read_text())
RESULTS = ROOT / "Benchmarks/local-results.json"

def snapshot(model: str) -> Path:
    folder = Path.home()/'.cache/huggingface/hub'/('models--'+model.replace('/','--'))/'snapshots'
    choices = [p for p in folder.glob('*') if (p/'config.json').exists()]
    if not choices: raise SystemExit(f"Model is not cached: {model}")
    return max(choices, key=lambda p:p.stat().st_mtime)

def run(model: str, capability: str) -> dict:
    task = TASKS[capability]; profile = PROFILES.get(model, {}); backend = profile.get('backend','mlx-lm')
    model_path = snapshot(model); inputs = task.get('inputs') or ([task['input']] if task.get('input') else [])
    inputs = [str(ROOT/p) for p in inputs]
    prompt = task['prompt']
    if backend == 'mlx-lm':
        for value in inputs:
            if Path(value).suffix.lower() in {'.py','.swift','.txt','.json'}: prompt += '\n\n'+Path(value).read_text()
        cmd=[str(Path.home()/'.local/bin/mlx_lm.generate'),'--model',str(model_path),'--prompt',prompt,'--max-tokens','512','--temp','0','--verbose','true']
        cwd=ROOT; output_file=None
    elif backend == 'mlx-vlm':
        image_inputs=[str(ROOT/'Benchmarks/fixtures/room.png') if Path(v).suffix.lower()=='.pdf' else v for v in inputs]
        cmd=[str(Path.home()/'.local/bin/mlx_vlm.generate'),'--model',str(model_path),'--image',*image_inputs,'--prompt',prompt,'--max-tokens','512','--temperature','0','--verbose']
        cwd=ROOT; output_file=None
    elif backend == 'whisper-mlx':
        temp=Path(tempfile.mkdtemp(prefix='mlx-menu-benchmark-')); output_file=temp/'transcript.json'
        cmd=[str(Path.home()/'.local/bin/mlx_audio.stt.generate'),'--model',str(model_path),'--audio',inputs[0],'--output-path','transcript','--format','json','--max-tokens','1024','--verbose']
        cwd=temp
    else: raise SystemExit(f"Unsupported backend: {backend}")
    env={**os.environ,'HF_HUB_OFFLINE':'1','PYTHONUNBUFFERED':'1'}
    started=time.perf_counter(); proc=subprocess.run(cmd,cwd=cwd,env=env,text=True,capture_output=True); elapsed=(time.perf_counter()-started)*1000
    raw=proc.stdout+'\n'+proc.stderr
    if output_file and output_file.exists(): raw += '\n'+output_file.read_text()
    lower=raw.lower(); expected=task.get('expected',[]); hits=sum(term.lower() in lower for term in expected)
    quality=hits/max(len(expected),1)
    malformed=0
    if task.get('require_json'):
        matches=re.findall(r'\{.*?\}',raw,re.S)
        if not any(_valid_json(x) for x in matches): malformed=1; quality*=0.5
    tps=_number(raw,r'Generation:\s*\d+ tokens,\s*([\d.]+) tokens-per-sec')
    memory=_number(raw,r'Peak memory:\s*([\d.]+) GB')
    return {'capability':capability,'quality':quality,'firstTokenMilliseconds':None,
            'totalMilliseconds':round(elapsed,2),'tokensPerSecond':tps,
            'peakMemoryBytes':int(memory*1e9) if memory is not None else None,
            'measuredAt':datetime.now(timezone.utc).isoformat().replace('+00:00','Z'),
            'failures':0 if proc.returncode==0 else 1,'malformedOutputs':malformed,
            '_command':' '.join(cmd),'_exit':proc.returncode,'_output':raw[-4000:]}

def _number(text, pattern):
    m=re.search(pattern,text,re.I); return float(m.group(1)) if m else None

def _valid_json(value):
    try: json.loads(value); return True
    except Exception: return False

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--model',required=True); parser.add_argument('--capability',choices=TASKS); parser.add_argument('--all',action='store_true'); parser.add_argument('--no-save',action='store_true')
    args=parser.parse_args(); capabilities=PROFILES.get(args.model,{}).get('capabilities',[])
    selected=list(TASKS) if args.all else [args.capability] if args.capability else []
    selected=[c for c in selected if c in capabilities]
    if not selected: raise SystemExit('No selected task is compatible with the model profile.')
    data=json.loads(RESULTS.read_text()) if RESULTS.exists() else {}; records=data.get(args.model,[])
    for capability in selected:
        print(f'Benchmarking {args.model} / {capability}...',flush=True); record=run(args.model,capability)
        print(json.dumps({k:v for k,v in record.items() if not k.startswith('_')},indent=2))
        records=[r for r in records if r['capability']!=capability]+[{k:v for k,v in record.items() if not k.startswith('_') and v is not None}]
        if record['_exit'] or record['malformedOutputs']: print(record['_output'])
    data[args.model]=records
    if not args.no_save: RESULTS.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')

if __name__=='__main__': main()
