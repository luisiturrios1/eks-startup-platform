#!/usr/bin/env python3
"""Render disposable kind workloads. No AWS configuration is consumed."""
import yaml, subprocess, json, argparse
from pathlib import Path
from compile_services import compile_config
parser=argparse.ArgumentParser();parser.add_argument("--stage",choices=["migrations","runtime"],required=True);args=parser.parse_args()
objects=[]
addresses=json.loads(Path("local/network.generated.json").read_text())
image_id=subprocess.check_output(["docker","inspect","--format","{{.Id}}","platform-examples:local"],text=True).strip()
for name,svc in compile_config('dev')['services'].items():
    objects.append({'apiVersion':'v1','kind':'Namespace','metadata':{'name':name,'labels':{'pod-security.kubernetes.io/enforce':'restricted'}}})
    base={'name':'service','image':'platform-examples:local','imagePullPolicy':'Never','env':[{'name':k,'value':v} for k,v in {'SERVICE_NAME':name,'SPRING_PROFILES_ACTIVE':'local','AWS_REGION':'us-east-1','AWS_ACCESS_KEY_ID':'test','AWS_SECRET_ACCESS_KEY':'test','AWS_ENDPOINT_URL':'http://'+addresses['ministack']+':4566','DB_HOST_OVERRIDE':addresses[name],'DB_PORT_OVERRIDE':'5432' if svc['engine']=='postgres' else '3306','DB_SECRET_ID':f'local/{name}/runtime','DB_ENGINE':svc['engine'],'CACHE_HOST':addresses['valkey'],'CACHE_USER':name,'CACHE_PASSWORD':'local-payments-only' if name=='payments-service' else 'local-auth-only','S3_BUCKET':'local-'+name}.items()], 'securityContext':{'allowPrivilegeEscalation':False,'readOnlyRootFilesystem':True,'capabilities':{'drop':['ALL']}},'resources':svc['resources'],'volumeMounts':[{'name':'tmp','mountPath':'/tmp'}]}
    security={'runAsNonRoot':True,'runAsUser':10001,'runAsGroup':10001,'seccompProfile':{'type':'RuntimeDefault'}}
    import copy
    migration=copy.deepcopy(base)
    for e in migration['env']:
        if e['name']=='SPRING_PROFILES_ACTIVE':e['value']='local,migration'
        if e['name']=='DB_SECRET_ID':e['value']=f'local/{name}/migration'
    pod={'securityContext':security,'restartPolicy':'Never','containers':[migration],'volumes':[{'name':'tmp','emptyDir':{}}]}
    objects.append({'apiVersion':'batch/v1','kind':'Job','metadata':{'name':'migrate','namespace':name},'spec':{'backoffLimit':0,'activeDeadlineSeconds':180,'template':{'metadata':{'labels':{'app':name}},'spec':pod}}})
    base.update(ports=[{'containerPort':8080}],readinessProbe={'httpGet':{'path':'/actuator/health/readiness','port':8080},'initialDelaySeconds':15})
    runtime={'securityContext':security,'containers':[base],'volumes':[{'name':'tmp','emptyDir':{}}]}
    objects.append({'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':name,'namespace':name},'spec':{'replicas':1,'selector':{'matchLabels':{'app':name}},'template':{'metadata':{'labels':{'app':name},'annotations':{'platform.local/image-id':image_id}},'spec':runtime}}})
    objects.append({'apiVersion':'v1','kind':'Service','metadata':{'name':name,'namespace':name},'spec':{'selector':{'app':name},'ports':[{'port':8080}]}})
    objects.append({'apiVersion':'networking.k8s.io/v1','kind':'NetworkPolicy','metadata':{'name':'isolate-services','namespace':name},'spec':{'podSelector':{},'policyTypes':['Ingress'],'ingress':[{'from':[{'podSelector':{}}]}]}})
objects=[obj for obj in objects if (args.stage=="migrations" and obj["kind"] not in ["Deployment","Service"]) or (args.stage=="runtime" and obj["kind"]!="Job")]
print(yaml.safe_dump_all(objects,sort_keys=False))
