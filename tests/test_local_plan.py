"""Reject unsafe or incomplete saved local plans before publishing evidence."""
import importlib.util
from pathlib import Path
import sys
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
spec = importlib.util.spec_from_file_location('local_plan', ROOT/'scripts/local_plan.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def test_replacement_is_not_accepted_as_create_only():
    with pytest.raises(ValueError, match='create-only'):
        p.inspect_plan({'resource_changes': [{'change': {'actions': ['delete', 'create']}}]}, 'us-east-1')


def test_missing_cluster_is_rejected():
    with pytest.raises(ValueError, match='Required planned resources'):
        p.inspect_plan({'resource_changes': []}, 'us-west-2')


def test_local_process_does_not_inherit_operator_credentials(tmp_path, monkeypatch):
    monkeypatch.setattr(p, 'BUILD', tmp_path)
    monkeypatch.setenv('AWS_PROFILE', 'production')
    monkeypatch.setenv('AWS_ACCESS_KEY_ID', 'operator-key')
    monkeypatch.setenv('TF_CLI_ARGS_plan', '-target=wrong')
    env = p.environment()
    assert 'AWS_PROFILE' not in env and 'AWS_ACCESS_KEY_ID' not in env
    assert 'TF_CLI_ARGS_plan' not in env and env['TF_WORKSPACE'] == 'default'


def test_namespace_chart_retains_restricted_namespaces():
    import subprocess
    import yaml
    rendered = subprocess.check_output(['helm', 'template', 'namespaces', str(ROOT/'charts/namespaces'),
                                         '--set', 'namespaces[0]=payments-service', '--set', 'namespaces[1]=auth-service'], text=True)
    objects = list(yaml.safe_load_all(rendered))
    assert {item['metadata']['name'] for item in objects} == {'payments-service', 'auth-service'}
    for item in objects:
        assert item['kind'] == 'Namespace'
        assert item['metadata']['labels']['pod-security.kubernetes.io/enforce'] == 'restricted'
        assert item['metadata']['annotations']['helm.sh/resource-policy'] == 'keep'


def test_export_preserves_contract_namespace_ownership(tmp_path):
    import json
    import subprocess
    data = {'services': {name: {'dependencies': []} for name in ['payments-service', 'auth-service']},
            'region': 'us-east-1', 'vpc_cidr': '10.40.0.0/16', 'service_cidr': '172.20.0.0/16'}
    source = tmp_path/'outputs.json'
    source.write_text(json.dumps(data))
    subprocess.run([sys.executable, str(ROOT/'scripts/export_values.py'), str(source), '--environment', 'dev'], cwd=tmp_path, check=True)
    result = json.loads((tmp_path/'build/dev/platform.auto.tfvars.json').read_text())
    assert result['service_namespaces'] == ['auth-service', 'payments-service']
    assert result['platform'] == data
