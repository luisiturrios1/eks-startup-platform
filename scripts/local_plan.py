#!/usr/bin/env python3
"""Plan the shared platform in two emulator regions and namespaces in disposable kind.

Only init, validate, workspace show, plan and show are executed. Never apply.
"""
import argparse
from collections import Counter
import json
import os
import subprocess
import urllib.request

import boto3
from compile_services import ROOT, compile_config

BUILD = ROOT / 'build/local-plan'
REGIONS = ('us-east-1', 'us-west-2')
ENDPOINT = 'http://127.0.0.1:14566'


def prepare():
    BUILD.mkdir(parents=True, exist_ok=True, mode=0o700)
    BUILD.chmod(0o700)
    (BUILD / 'contracts.json').write_text(json.dumps(compile_config('dev'), indent=2) + '\n')


def environment():
    # Do not inherit credentials, profile processes or Terraform CLI argument overrides.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('AWS_', 'TF_CLI_ARGS', 'TF_WORKSPACE', 'TF_DATA_DIR'))}
    empty = BUILD / 'empty-aws-config'
    empty.write_text('')
    empty.chmod(0o600)
    env.update(AWS_CONFIG_FILE=str(empty), AWS_SHARED_CREDENTIALS_FILE=str(empty),
               AWS_EC2_METADATA_DISABLED='true', TF_WORKSPACE='default', TF_IN_AUTOMATION='1')
    return env


def inspect_plan(data, label):
    changes = data.get('resource_changes', [])
    counts = Counter(action for item in changes for action in item['change']['actions'])
    if any(action not in ('create', 'no-op', 'read') for action in counts):
        raise ValueError('Local review requires a fresh create-only plan: ' + str(dict(counts)))
    resources = {item['type'] for item in changes if item['change']['actions'] == ['create']}
    required = {'aws_eks_cluster', 'aws_eks_node_group', 'aws_iam_role_policy', 'aws_s3_bucket'} if label in REGIONS else {'helm_release'}
    if not required <= resources:
        raise ValueError('Required planned resources missing: ' + str(required - resources))
    if label in REGIONS:
        cluster = next(item['change']['after'] for item in changes if item['type'] == 'aws_eks_cluster')
        if cluster['vpc_config'][0]['endpoint_public_access'] or not cluster['vpc_config'][0]['endpoint_private_access']:
            raise ValueError('The shared module must keep the EKS API private')
    return {'target': label, 'actions': dict(sorted(counts.items())),
            'planned_resources': sorted(item['address'] for item in changes if item['change']['actions'] == ['create']),
            'outputs': {key: value.get('value') for key, value in data.get('planned_values', {}).get('outputs', {}).items()}}


def terraform_plan(label, root, env):
    directory = BUILD / label
    directory.mkdir(exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    env = dict(env, TF_DATA_DIR=str(directory / '.terraform-local'))
    def run(*args, capture=False):
        return subprocess.run(['terraform', '-chdir=' + str(root), *args], env=env,
                              text=True, check=True, capture_output=capture)
    run('init', '-input=false', '-lockfile=readonly', '-backend-config=path=' + str(directory / 'terraform.tfstate'))
    run('validate', '-no-color')
    if run('workspace', 'show', capture=True).stdout.strip() != 'default':
        raise ValueError('Unexpected Terraform workspace')
    plan = directory / 'review.tfplan'
    args = ['plan', '-input=false', '-no-color', '-out=' + str(plan)]
    if label in REGIONS:
        args.append('-var-file=' + str(root / (label + '.tfvars')))
    run(*args)
    # Inspect the saved artifact, not a second speculative plan.
    text = run('show', '-no-color', str(plan), capture=True).stdout
    (directory / 'review.txt').write_text(text)
    data = json.loads(run('show', '-json', str(plan), capture=True).stdout)
    summary = inspect_plan(data, label)
    (directory / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Reviewed plan:', label, summary['actions'], flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true', help='Compile schema-validated contracts without contacting an API')
    parser.add_argument('--region', action='append', choices=REGIONS, help='Plan selected emulator region(s)')
    parser.add_argument('--namespaces', action='store_true', help='Plan namespaces against kind-platform-review')
    args = parser.parse_args()
    os.umask(0o077)
    prepare()
    if args.prepare_only:
        print('Prepared non-secret local service contracts')
        return
    env = environment()
    os.environ.clear()
    os.environ.update(env)
    regions = args.region or ([] if args.namespaces else list(REGIONS))
    if regions:
        with urllib.request.urlopen(ENDPOINT + '/_ministack/health', timeout=5) as response:
            json.load(response)
    for region in regions:
        client = boto3.client('sts', region_name=region, endpoint_url=ENDPOINT,
                              aws_access_key_id='test', aws_secret_access_key='test')
        if client.get_caller_identity()['Account'] != '000000000000':
            raise ValueError('Unexpected emulator account')
        terraform_plan(region, ROOT / 'examples/local-plan/infrastructure', env)
    if args.namespaces or not args.region:
        subprocess.run(['kubectl', '--context=kind-platform-review', 'get', '--raw=/readyz'], check=True, env=env)
        terraform_plan('kubernetes', ROOT / 'examples/local-plan/kubernetes', env)


if __name__ == '__main__':
    main()
