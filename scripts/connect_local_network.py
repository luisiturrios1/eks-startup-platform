#!/usr/bin/env python3
"""Attach only this local demo's dependencies to kind's Docker network."""
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
names=subprocess.check_output(['docker','ps','--format','{{.Names}}'],text=True).splitlines()
targets={'ministack':'eks-platform-local-ministack-1','valkey':'eks-platform-local-valkey-1'}
for service in ['payments-service','auth-service']:
    targets[service]=next(n for n in names if n.startswith('ministack-rds-') and n.endswith('-'+service))
addresses={}
for key,name in targets.items():
    networks=json.loads(subprocess.check_output(['docker','inspect',name]))[0]['NetworkSettings']['Networks']
    if 'kind' not in networks:subprocess.run(['docker','network','connect','kind',name],check=True)
    networks=json.loads(subprocess.check_output(['docker','inspect',name]))[0]['NetworkSettings']['Networks']
    addresses[key]=networks['kind']['IPAddress']
(ROOT/'local/network.generated.json').write_text(json.dumps(addresses,indent=2)+'\n')
