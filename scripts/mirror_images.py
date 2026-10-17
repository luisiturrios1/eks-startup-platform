#!/usr/bin/env python3
"""Operator-only image promotion using skopeo; preserves multi-architecture digests."""
import argparse,json,re,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--repository',required=True);p.add_argument('--approved',action='store_true');args=p.parse_args()
if not re.fullmatch(r'[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[^:@]+',args.repository):raise SystemExit('Expected private ECR repository URL')
root=Path(__file__).resolve().parents[1];images=json.loads((root/'config/images.lock.json').read_text());result={}
for name,image in images.items():
    if name in ['maven','java','lambda']:continue
    source=image['source'].split('@')[0]+'@'+image['digest']
    target=args.repository+':'+name+'-'+image['digest'].split(':')[1][:16]
    command=['skopeo','copy','--all','--preserve-digests','docker://'+source,'docker://'+target]
    if args.approved:
        subprocess.run(command,check=True)
        actual=subprocess.check_output(['skopeo','inspect','--format','{{.Digest}}','docker://'+target],text=True).strip()
        if actual!=image['digest']:raise SystemExit('Mirrored digest mismatch: '+name)
    else:print(' '.join(command))
    result[name]={'repository':args.repository,'digest':image['digest']}
if args.approved:
    (root/'build').mkdir(exist_ok=True)
    (root/'build/images.auto.tfvars.json').write_text(json.dumps({'images':result},indent=2)+'\n')
    print('Wrote build/images.auto.tfvars.json')
