"""Exercise allowed and denied flows against the rendered Kubernetes policies."""
import ipaddress
import subprocess
from pathlib import Path

import hcl2
import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart):
    output = subprocess.check_output(['helm', 'template', 'test', str(ROOT/'charts'/chart)], text=True)
    return [item for item in yaml.safe_load_all(output) if item]


@pytest.fixture(scope='module')
def policies():
    objects = render('system-network') + render('platform') + render('service')
    return [item for item in objects if item['kind'] == 'NetworkPolicy']


def pod(namespace, name, ip='10.40.48.10', **labels):
    return dict(namespace=namespace, ip=ip, labels={'app.kubernetes.io/name': name, **labels})


def selector_matches(selector, labels):
    if not all(labels.get(key) == value for key, value in selector.get('matchLabels', {}).items()):
        return False
    for item in selector.get('matchExpressions', []):
        assert item['operator'] == 'In'
        if labels.get(item['key']) not in item['values']:
            return False
    return True


def peer_matches(peer, endpoint, policy_namespace):
    if 'ipBlock' in peer:
        address = ipaddress.ip_address(endpoint['ip'])
        block = peer['ipBlock']
        return address in ipaddress.ip_network(block['cidr']) and not any(
            address in ipaddress.ip_network(cidr) for cidr in block.get('except', []))
    if 'namespaceSelector' in peer:
        if endpoint['namespace'] is None or not selector_matches(
                peer['namespaceSelector'], {'kubernetes.io/metadata.name': endpoint['namespace']}):
            return False
    elif endpoint['namespace'] != policy_namespace:
        return False
    return selector_matches(peer.get('podSelector', {}), endpoint['labels'])


def direction_allowed(policies, endpoint, peer, port, protocol, direction):
    selected = [p for p in policies if p['metadata']['namespace'] == endpoint['namespace']
                and direction.title() in p['spec']['policyTypes']
                and selector_matches(p['spec']['podSelector'], endpoint['labels'])]
    # Strict VPC CNI denies unconfigured managed pods; external endpoints have no pod policy.
    if not selected:
        return endpoint['namespace'] is None
    key = 'to' if direction == 'egress' else 'from'
    for policy in selected:
        for rule in policy['spec'].get(direction, []):
            ports = rule.get('ports', [])
            if ports and not any(p.get('protocol', 'TCP') == protocol and p['port'] == port for p in ports):
                continue
            peers = rule.get(key, [])
            if not peers or any(peer_matches(p, peer, endpoint['namespace']) for p in peers):
                return True
    return False


def allows(policies, source, destination, port, protocol='TCP'):
    return direction_allowed(policies, source, destination, port, protocol, 'egress') and direction_allowed(
        policies, destination, source, port, protocol, 'ingress')


def test_dns_and_controller_bootstrap_paths(policies):
    dns = pod('kube-system', 'coredns', **{'k8s-app': 'kube-dns'})
    api = pod(None, 'api', ip='172.20.0.1')
    private_endpoint = pod(None, 'endpoint', ip='10.40.50.10')
    resolver = pod(None, 'resolver', ip='10.40.0.2')
    assert allows(policies, dns, api, 443)
    assert allows(policies, dns, resolver, 53, 'UDP')
    for namespace, name in [('kube-system', 'karpenter'), ('kube-system', 'aws-load-balancer-controller'),
                            ('kube-system', 'metrics-server'), ('cert-manager', 'cert-manager')]:
        source = pod(namespace, name)
        assert allows(policies, source, dns, 53, 'UDP'), (namespace, name, 'DNS')
        assert allows(policies, source, api, 443), (namespace, name, 'API')
        assert allows(policies, source, private_endpoint, 443), (namespace, name, 'private endpoint')
        assert not allows(policies, source, pod(None, 'internet', ip='1.1.1.1'), 443)
        assert not allows(policies, source, pod(None, 'metadata', ip='169.254.169.254'), 80)


def test_identity_webhook_and_metrics_paths(policies):
    identity = pod(None, 'identity', ip='169.254.170.23')
    for name in ['karpenter', 'aws-load-balancer-controller']:
        assert allows(policies, pod('kube-system', name), identity, 80)
    assert not allows(policies, pod('kube-system', 'metrics-server'), identity, 80)
    api = pod(None, 'api', ip='10.40.48.20')
    assert allows(policies, api, pod('kube-system', 'aws-load-balancer-controller'), 9443)
    assert allows(policies, api, pod('kube-system', 'metrics-server'), 10250)
    webhook = pod('cert-manager', 'cert-manager-webhook', **{'app.kubernetes.io/component': 'webhook'})
    assert allows(policies, api, webhook, 10250)
    assert allows(policies, pod('cert-manager', 'startupapicheck'), webhook, 10250)
    assert allows(policies, pod('kube-system', 'metrics-server'), pod(None, 'kubelet'), 10250)


def test_telemetry_and_application_isolation(policies):
    collector = pod('amazon-cloudwatch', 'otel', app='telemetry')
    runtime = pod('payments-service', 'payments-service', role='runtime')
    assert allows(policies, runtime, collector, 4318)
    assert not allows(policies, pod('cert-manager', 'cert-manager'), collector, 4318)
    assert allows(policies, collector, pod(None, 'kubelet'), 10250)
    assert allows(policies, collector, pod(None, 'identity', ip='169.254.170.23'), 80)
    assert not allows(policies, collector, pod(None, 'internet', ip='1.1.1.1'), 443)
    assert not allows(policies, pod('kube-system', 'karpenter'), runtime, 8443)


def test_network_policies_precede_dns_and_controllers_in_every_root():
    for environment in ['dev', 'staging', 'prod']:
        with (ROOT/'kubernetes'/environment/'main.tf').open() as stream:
            data = hcl2.load(stream, serialization_options=hcl2.utils.SerializationOptions(strip_string_quotes=True, explicit_blocks=False, with_comments=False))
        resources = {f'{kind}.{name}': body for block in data['resource']
                     for kind, names in block.items() for name, body in names.items()}
        assert resources['aws_eks_addon.coredns']['depends_on'] == ['${helm_release.network}']
        for name in ['cert_manager', 'karpenter', 'load_balancer', 'metrics']:
            assert resources[f'helm_release.{name}']['depends_on'] == ['${aws_eks_addon.coredns}']


def test_scanner_exception_is_exactly_one_workload():
    exceptions = yaml.safe_load((ROOT/'.trivyignore.yaml').read_text())['misconfigurations']
    assert len(exceptions) == 1
    assert exceptions[0]['id'] == 'AVD-KSV-0118'
    target = Path(exceptions[0]['paths'][0]).relative_to('charts/platform')
    output = subprocess.check_output(['helm', 'template', 'test', str(ROOT/'charts/platform'), '--show-only', str(target)], text=True)
    documents = list(yaml.safe_load_all(output))
    assert len(documents) == 1
    assert documents[0]['kind'] == 'DaemonSet'
    assert documents[0]['metadata'] == {'name': 'fluent-bit', 'namespace': 'amazon-cloudwatch'}
    assert str(exceptions[0]['expired_at']) == '2027-01-16'
