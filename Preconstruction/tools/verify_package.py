#!/usr/bin/env python3
"""Verify package hashes, source provenance, JSON/Python syntax, links and secret-signature tripwires.
No network/model execution. This is package integrity, not construction QA.
"""
from pathlib import Path
import ast,hashlib,json,re,sys
P=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 errors=[];files=[p for p in P.rglob('*') if p.is_file()]
 for p in files:
  if p.is_symlink():errors.append(f'symlink: {p.relative_to(P)}')
  if any(x in p.parts for x in ['__pycache__','node_modules','.git']):errors.append(f'unexpected runtime/cache content: {p.relative_to(P)}')
  if p.suffix=='.json':
   try:json.loads(p.read_text())
   except Exception as e:errors.append(f'JSON {p.relative_to(P)}: {e}')
  if p.suffix=='.py':
   try:ast.parse(p.read_text())
   except Exception as e:errors.append(f'Python {p.relative_to(P)}: {e}')
  if p.suffix in ['.md','.txt','.json','.yaml','.py','.sh','.csv']:
   s=p.read_text()
   if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bsk-[A-Za-z0-9]{24,}|\bAKIA[A-Z0-9]{16}\b',s):errors.append(f'secret signature: {p.relative_to(P)}')
  if p.suffix=='.md':
   for target in re.findall(r'\[[^\]]+\]\(([^\s)]+)\)',p.read_text()):
    if re.match(r'(?:https?:|mailto:|#)',target) or '<' in target:continue
    target=target.split('#')[0]
    if target and not (p.parent/target).exists():errors.append(f'broken local link: {p.relative_to(P)} -> {target}')
 manifest=json.loads((P/'provenance/source-manifest.json').read_text())
 for row in manifest['source_files']:
  p=P/row['package_path']
  if not p.is_file() or sha(p)!=row['packaged_sha256']:errors.append('source checksum mismatch: '+row['package_path'])
 hashfile=P/'provenance/package-files.sha256.json'
 if hashfile.exists():
  expected=json.loads(hashfile.read_text())
  actual={str(p.relative_to(P)):sha(p) for p in files if p!=hashfile}
  if expected!=actual:
   errors.extend('package checksum mismatch: '+k for k in sorted(set(expected)|set(actual)) if expected.get(k)!=actual.get(k))
 else:errors.append('missing package checksum manifest')
 if errors:
  print('\n'.join(errors),file=sys.stderr);return 1
 print(json.dumps({'status':'passed','files':len(files),'source_files':len(manifest['source_files']),'checks':['package/source hashes','JSON syntax','Python syntax','local Markdown links','secret-signature tripwires'],'limits':['tripwires are not exhaustive secret detection','no inference, application feature or construction accuracy claim']}))
 return 0
if __name__=='__main__':raise SystemExit(main())
