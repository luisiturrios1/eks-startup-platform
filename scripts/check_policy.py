#!/usr/bin/env python3
"""Fail closed on platform security invariants, independent of scanner heuristics."""
import json,sys
from pathlib import Path
import hcl2
ROOT=Path(__file__).resolve().parents[1]
def resources(directory):
    result={}
    for file in directory.glob('*.tf'):
        with file.open() as stream:data=hcl2.load(stream, serialization_options=hcl2.utils.SerializationOptions(strip_string_quotes=True, explicit_blocks=False, with_comments=False))
        for block in data.get('resource',[]):
            for kind,names in block.items():
                for name,body in names.items():result[kind+'.'+name]=body
    return result

def evaluate(platform,network):
    failures=[]
    def require(ok,message):
        if not ok:failures.append(message)
    cluster=platform['aws_eks_cluster.this']['vpc_config'][0]
    require(cluster['endpoint_public_access'] is False and cluster['endpoint_private_access'] is True,'EKS API must be private')
    db=platform['aws_db_instance.this']
    for key in ['storage_encrypted','manage_master_user_password','deletion_protection']:require(db.get(key) is True,'RDS requires '+key)
    require(db.get('publicly_accessible') is False,'Public RDS forbidden')
    cache=platform['aws_elasticache_replication_group.this']
    require(cache.get('engine')=='valkey' and cache.get('transit_encryption_enabled') is True and cache.get('at_rest_encryption_enabled') is True,'Managed Valkey encryption required')
    require(not any(k.startswith('aws_nat_gateway.') for k in network),'NAT forbidden in isolated platform')
    for key,route in network.items():
        if key.startswith('aws_route.') and route.get('destination_cidr_block')=='0.0.0.0/0':
            require(route.get('route_table_id')=='${aws_route_table.public.id}','Internet route outside ingress subnets')
    require('aws_wafv2_web_acl_association.api' in platform,'Public ALB requires WAF')
    require(not any(k.startswith('aws_secretsmanager_secret_version.') for k in platform),'Secret values must not enter Terraform state')
    return failures

def main():
    failures=evaluate(resources(ROOT/'modules/platform'),resources(ROOT/'modules/networking'))
    for workflow in (ROOT/'.github/workflows').glob('*.yaml'):
        text=workflow.read_text()
        for forbidden in ['terraform apply','terraform destroy','configure-aws-credentials','id-token: write','pull_request_target']:
            if forbidden in text:failures.append('Privileged CI operation: '+forbidden)
    if failures:raise SystemExit('\n'.join(failures))
    print('Platform policy checks passed')
if __name__=='__main__':main()
