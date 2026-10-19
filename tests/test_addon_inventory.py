"""Ensure the AWS-managed exception is sourced from the verified account/cluster/version."""
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('inventory', ROOT/'scripts/export_addon_images.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def setup_inventory(mutation=None):
    platform = {'account_id': '111111111111', 'cluster_name': 'test', 'region': 'us-east-1',
                'cluster_endpoint': 'https://test.eks.amazonaws.com',
                'addon_versions': {addon: 'v1.2.3-eksbuild.1' for addon in m.WORKLOADS}}

    def run(args, **kwargs):
        if args[1:3] == ['sts', 'get-caller-identity']:
            return json.dumps({'Account': '222222222222' if mutation == 'account' else platform['account_id']})
        if args[1:3] == ['eks', 'describe-cluster']:
            return json.dumps({'cluster': {'endpoint': platform['cluster_endpoint']}})
        if 'view' in args:
            return json.dumps({'clusters': [{'cluster': {'server': 'https://wrong.example' if mutation == 'context' else platform['cluster_endpoint']}}]})
        if 'describe-addon' in args:
            return json.dumps({'addon': {'status': 'DEGRADED' if mutation == 'status' else 'ACTIVE',
                                         'addonVersion': 'v9' if mutation == 'version' else 'v1.2.3-eksbuild.1'}})
        name = args[args.index('get')+2]
        image = '602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/'+name+':v1.2.3-eksbuild.1'
        if mutation == 'image':
            image = 'docker.io/library/nginx:latest'
        if mutation == 'alias':
            image = image.rsplit(':', 1)[0]+':latest'
        return json.dumps({'spec': {'template': {'spec': {'serviceAccountName': 'wrong' if mutation == 'serviceaccount' else name,
                                                         'containers': [{'name': 'addon', 'image': image}],
                                                         'initContainers': [{'name': 'init', 'image': image}]}}}})
    return platform, run


def test_exact_inventory_from_all_managed_addons():
    platform, run = setup_inventory()
    images = m.inventory(platform, 'expected', run)['managed_addon_images']
    assert set(images) == {'aws-node', 'kube-proxy', 'coredns', 'eks-pod-identity-agent'}
    assert all(len(references) == 1 for references in images.values())
    assert all(references[0].endswith(':v1.2.3-eksbuild.1') for references in images.values())


@pytest.mark.parametrize('mutation', ['account', 'context', 'status', 'version', 'image', 'alias', 'serviceaccount'])
def test_unverified_inventory_is_rejected(mutation):
    platform, run = setup_inventory(mutation)
    with pytest.raises(ValueError):
        m.inventory(platform, 'expected', run)
