#!/usr/bin/env python3
"""Read-only deployment prerequisite checks. Never writes cloud resources."""
import argparse,json,ipaddress
from pathlib import Path
import boto3
from compile_services import compile_config
p=argparse.ArgumentParser();p.add_argument('--environment',required=True,choices=['dev','staging','prod']);p.add_argument('--vars',required=True);args=p.parse_args()
v=json.loads(Path(args.vars).read_text());region=v.get('region','us-east-1')
vpc=ipaddress.ip_network(v['vpc_cidr']);vpn=ipaddress.ip_network(v['vpn_client_cidr'])
if vpc.overlaps(vpn):raise SystemExit('VPN client CIDR overlaps VPC')
if vpc.version!=4 or vpc.prefixlen!=16:raise SystemExit('This platform subnet layout requires an IPv4 /16 VPC')
session=boto3.Session(region_name=region)
account=session.client('sts').get_caller_identity()['Account']
if account!=v['account_id']:raise SystemExit('AWS identity does not match expected account')
if (args.environment=='prod') != (account==v['production_account_id']):raise SystemExit('Production account isolation violation')
ec2=session.client('ec2');zones=ec2.describe_availability_zones(ZoneIds=v['availability_zone_ids'])['AvailabilityZones']
if len(zones)!=3 or any(z['State']!='available' for z in zones):raise SystemExit('Three available pinned AZs required')
services=ec2.describe_vpc_endpoint_services()['ServiceNames']
for endpoint in ['ecr.api','ecr.dkr','ec2','eks','eks-auth','sts','secretsmanager','kms','logs','monitoring','xray','ssm','sqs','elasticloadbalancing','s3']:
    if f'com.amazonaws.{region}.{endpoint}' not in services:raise SystemExit('Missing private endpoint: '+endpoint)
configuration=compile_config(args.environment)
rds=session.client('rds')
for name,db in configuration['database_instances'].items():
    versions=rds.describe_db_engine_versions(Engine=db['engine'])['DBEngineVersions']
    candidates=[item['EngineVersion'] for item in versions if item['EngineVersion']==db['engine_version'] or item['EngineVersion'].startswith(db['engine_version']+'.')]
    if not candidates:raise SystemExit('Unavailable engine version: '+name)
    offerings=[]
    for version in candidates:
        offerings.extend(rds.describe_orderable_db_instance_options(Engine=db['engine'],EngineVersion=version,DBInstanceClass=db['instance_class'])['OrderableDBInstanceOptions'])
    if not offerings:raise SystemExit('Unavailable RDS engine/version/size: '+name)
    if args.environment=='prod' and not any(o.get('MultiAZCapable') for o in offerings):raise SystemExit('Multi-AZ unavailable: '+name)
cache=session.client('elasticache').describe_cache_engine_versions(Engine='valkey',EngineVersion='8.0')['CacheEngineVersions']
if not cache:raise SystemExit('Valkey engine unavailable')
eks=session.client('eks')
for addon,version in v['addons'].items():
    response=eks.describe_addon_versions(addonName=addon,kubernetesVersion=v.get('kubernetes_version','1.35'))
    available={entry['addonVersion'] for item in response['addons'] for entry in item['addonVersions']}
    if version not in available:raise SystemExit(f'Unsupported add-on {addon} version; choose one of {sorted(available)}')
print('Account, AZ, private endpoint, engine and EKS add-on prerequisites passed. DNS, certificates, IdP MFA and quotas require operator review.')
