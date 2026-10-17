#!/usr/bin/env python3
"""Render pinned upstream charts with ECR overrides and enforce image policy."""
import json,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
repository='111111111111.dkr.ecr.us-east-1.amazonaws.com/platform-artifacts'
digest='sha256:'+'a'*64
image={'repository':repository,'digest':digest}
charts={
 'cert-manager-v1.21.2.tgz':{'crds':{'enabled':True},'image':image,'webhook':{'image':image},'cainjector':{'image':image},'startupapicheck':{'image':image}},
 'karpenter-1.15.0.tgz':{'settings':{'clusterName':'test','isolatedVPC':True},'controller':{'image':image}},
 'aws-load-balancer-controller-3.6.0.tgz':{'clusterName':'test','image':{'repository':repository,'tag':'@'+digest}},
 'metrics-server-3.13.0.tgz':{'image':{'repository':repository,'tag':'@'+digest}}
}
for chart,values in charts.items():
    with tempfile.NamedTemporaryFile(mode='w',suffix='.json') as file:
        json.dump(values,file);file.flush()
        rendered=subprocess.check_output(['helm','template','test',str(ROOT/'.artifacts'/chart),'--kube-version','1.35.0','--values',file.name])
        subprocess.run([str(ROOT/'scripts/helm_postrender.py')],input=rendered,check=True,stdout=subprocess.DEVNULL)
    print(chart+': private image overrides passed')
