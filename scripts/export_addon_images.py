#!/usr/bin/env python3
"""Read and inventory verified EKS-managed add-on templates for operator review."""
import argparse
import json
from pathlib import Path
import re
import subprocess

WORKLOADS = {
    'vpc-cni': ('daemonset', 'aws-node', 'aws-node'),
    'kube-proxy': ('daemonset', 'kube-proxy', 'kube-proxy'),
    'coredns': ('deployment', 'coredns', 'coredns'),
    'eks-pod-identity-agent': ('daemonset', 'eks-pod-identity-agent', 'eks-pod-identity-agent'),
}


def inventory(platform, context, run=subprocess.check_output):
    def command(args):
        return json.loads(run(args, text=True))

    account = command(['aws', 'sts', 'get-caller-identity', '--output', 'json'])['Account']
    if account != platform['account_id']:
        raise ValueError('AWS account does not match exported platform')
    cluster = command(['aws', 'eks', 'describe-cluster', '--name', platform['cluster_name'],
                       '--region', platform['region'], '--output', 'json'])['cluster']
    if cluster['endpoint'] != platform['cluster_endpoint']:
        raise ValueError('EKS endpoint does not match exported platform')
    configuration = command(['kubectl', '--context', context, 'config', 'view', '--minify', '-o', 'json'])
    if configuration['clusters'][0]['cluster']['server'] != cluster['endpoint']:
        raise ValueError('Kubernetes context does not match the expected EKS endpoint')
    result = {}
    for addon, (kind, name, account_name) in WORKLOADS.items():
        status = command(['aws', 'eks', 'describe-addon', '--cluster-name', platform['cluster_name'],
                          '--region', platform['region'], '--addon-name', addon, '--output', 'json'])['addon']
        if status['status'] != 'ACTIVE' or status['addonVersion'] != platform['addon_versions'][addon]:
            raise ValueError('Managed add-on is not ACTIVE at the approved version: ' + addon)
        workload = command(['kubectl', '--context', context, '-n', 'kube-system', 'get', kind, name, '-o', 'json'])
        spec = workload['spec']['template']['spec']
        if spec['serviceAccountName'] != account_name:
            raise ValueError('Unexpected managed add-on ServiceAccount: ' + addon)
        images = sorted({container['image'] for field in ['containers', 'initContainers']
                         for container in spec.get(field, [])})
        pattern = r'[0-9]{12}\.dkr\.ecr\.' + re.escape(platform['region']) + r'\.amazonaws\.com/[a-z0-9/_.-]+(?::v[0-9][a-zA-Z0-9_.-]*|@sha256:[a-f0-9]{64})'
        if not images or not all(re.fullmatch(pattern, image) for image in images):
            raise ValueError('Unexpected registry or mutable alias in managed add-on: ' + addon)
        result[account_name] = images
    return {'managed_addon_images': result}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('platform_output', help='Saved terraform output -json platform')
    parser.add_argument('--context', required=True)
    args = parser.parse_args()
    data = inventory(json.loads(Path(args.platform_output).read_text()), args.context)
    print(json.dumps(data, indent=2))


if __name__ == '__main__':
    main()
