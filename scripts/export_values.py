#!/usr/bin/env python3
"""Convert terraform output -json platform to non-secret deployment inputs."""
import argparse,ipaddress,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('output');p.add_argument('--environment',required=True,choices=['dev','staging','prod']);a=p.parse_args()
data=json.loads(Path(a.output).read_text());root=Path('build')/a.environment;root.mkdir(parents=True,exist_ok=True)
(root/'platform.auto.tfvars.json').write_text(json.dumps({'platform':data},indent=2))
for name,service in data['services'].items():
    values=dict(service,region=data['region'],vpcCidr=data['vpc_cidr'],serviceCidr=data['service_cidr'],production=a.environment=='prod',publicCidrs=[str(s) for s in list(ipaddress.ip_network(data['vpc_cidr']).subnets(new_prefix=20))[:3]],allowedCallers=[k for k,v in data['services'].items() if name in v['dependencies']])
    (root/(name+'.json')).write_text(json.dumps(values,indent=2))
print(root)
