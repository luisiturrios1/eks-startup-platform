"""Exercise the rendered policy in a real, node-free Kubernetes API server.

Opt in with PLATFORM_ADMISSION_INTEGRATION=1 and KUBEBUILDER_ASSETS pointing to
verified Kubernetes 1.35 envtest binaries. No Docker or AWS resources are used.
"""
import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import time

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
OWN = '111111111111.dkr.ecr.us-east-1.amazonaws.com/platform@sha256:'+'a'*64
AWS = '602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.12.0-eksbuild.1'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@pytest.fixture(scope='module')
def api(tmp_path_factory):
    if os.environ.get('PLATFORM_ADMISSION_INTEGRATION') != '1':
        pytest.skip('Set PLATFORM_ADMISSION_INTEGRATION=1 for a node-free local API test')
    binaries = Path(os.environ['KUBEBUILDER_ASSETS'])
    directory = tmp_path_factory.mktemp('admission-api')
    client, peer, secure = [free_port() for _ in range(3)]
    key = directory/'service-account.key'
    subprocess.run(['openssl', 'genrsa', '-out', str(key), '2048'], check=True, capture_output=True)
    (directory/'tokens.csv').write_text('local-admission-test,admin,admin,system:masters\n')
    client_url = f'http://127.0.0.1:{client}'
    peer_url = f'http://127.0.0.1:{peer}'
    commands = [
        [str(binaries/'etcd'), '--data-dir', str(directory/'etcd'),
         '--listen-client-urls', client_url, '--advertise-client-urls', client_url,
         '--listen-peer-urls', peer_url, '--initial-advertise-peer-urls', peer_url,
         '--initial-cluster', 'default='+peer_url],
        [str(binaries/'kube-apiserver'), '--etcd-servers='+client_url,
         '--secure-port='+str(secure), '--bind-address=127.0.0.1', '--advertise-address=127.0.0.1',
         '--cert-dir='+str(directory/'certs'), '--service-cluster-ip-range=172.20.0.0/16',
         '--service-account-issuer=https://local.admission.test',
         '--service-account-signing-key-file='+str(key), '--service-account-key-file='+str(key),
         '--token-auth-file='+str(directory/'tokens.csv'), '--authorization-mode=RBAC'],
    ]
    processes, logs = [], []
    config = directory/'kubeconfig.json'
    config.write_text(json.dumps({
        'apiVersion': 'v1', 'kind': 'Config', 'current-context': 'local',
        'clusters': [{'name': 'local', 'cluster': {'server': f'https://127.0.0.1:{secure}', 'insecure-skip-tls-verify': True}}],
        'contexts': [{'name': 'local', 'context': {'cluster': 'local', 'user': 'local'}}],
        'users': [{'name': 'local', 'user': {'token': 'local-admission-test'}}],
    }))

    def kubectl(*args, body=None):
        return subprocess.run([str(binaries/'kubectl'), '--kubeconfig', str(config), *args],
                              input=body, text=True, capture_output=True, timeout=20)

    try:
        for index, command in enumerate(commands):
            log = (directory/f'process-{index}.log').open('w')
            logs.append(log)
            processes.append(subprocess.Popen(command, stdout=log, stderr=log))
        for _ in range(60):
            if kubectl('get', '--raw=/readyz').returncode == 0:
                break
            if any(process.poll() is not None for process in processes):
                pytest.fail('Local API exited: '+str(directory))
            time.sleep(0.2)
        else:
            pytest.fail('Local API did not become ready: '+str(directory))
        for namespace in ['default', 'kube-system']:
            kubectl('create', 'namespace', namespace)
            # No controller manager runs in this test harness.
            result = kubectl('-n', namespace, 'create', 'serviceaccount', 'default')
            assert result.returncode == 0 or 'AlreadyExists' in result.stderr, result.stderr
        values = directory/'values.json'
        values.write_text(json.dumps({'managedAddonImages': {'coredns': [AWS]}}))
        manifest = subprocess.check_output(['helm', 'template', 'guardrails', str(ROOT/'charts/guardrails'),
                                            '-f', str(values)], text=True)
        result = kubectl('apply', '-f', '-', body=manifest)
        assert result.returncode == 0, result.stderr
        # Wait for policy compilation/cache propagation before testing requests.
        for _ in range(100):
            result = kubectl('create', '--dry-run=server', '-f', '-', body=json.dumps(pod('nginx:latest')))
            if 'Container images must' in result.stderr:
                break
            time.sleep(0.1)
        else:
            status = kubectl('get', 'validatingadmissionpolicy', 'platform-image-registry', '-o', 'json')
            pytest.fail('Policy did not enforce: '+status.stdout+result.stderr)
        status = json.loads(kubectl('get', 'validatingadmissionpolicy', 'platform-image-registry', '-o', 'json').stdout)
        assert not status.get('status', {}).get('typeChecking', {}).get('expressionWarnings'), status
        yield kubectl
    finally:
        for process in reversed(processes):
            process.terminate()
        for process in processes:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in logs:
            log.close()


def pod(image=OWN, namespace='default', account='default'):
    return {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'admission-test', 'namespace': namespace},
            'spec': {'serviceAccountName': account, 'containers': [{'name': 'app', 'image': image}]}}


def admit(api, manifest, expected):
    result = api('create', '--dry-run=server', '-f', '-', body=json.dumps(manifest))
    assert (result.returncode == 0) == expected, result.stdout+result.stderr
    if not expected:
        assert 'platform-image-registry' in result.stderr, result.stderr


def test_owned_image_and_exact_addon_exception(api):
    admit(api, pod(), True)
    result = api('-n', 'kube-system', 'create', 'serviceaccount', 'coredns')
    assert result.returncode == 0, result.stderr
    admit(api, pod(AWS, 'kube-system', 'coredns'), True)
    admit(api, pod(AWS, 'kube-system'), False)
    admit(api, pod(AWS), False)
    admit(api, pod(AWS.replace('v1.12.0', 'v1.99.0'), 'kube-system', 'coredns'), False)
    admit(api, pod('docker.io/library/nginx:latest', 'kube-system', 'coredns'), False)


@pytest.mark.parametrize('image', ['nginx:latest', OWN.replace('111111111111', '222222222222'),
                                  OWN.replace('us-east-1', 'us-west-2'), OWN.split('@')[0]+':latest'])
def test_foreign_or_mutable_image_rejected_by_api(api, image):
    admit(api, pod(image), False)


def test_init_sidecar_and_oci_volume_images(api):
    manifest = pod()
    manifest['spec']['initContainers'] = [{'name': 'init', 'image': OWN, 'restartPolicy': 'Always'}]
    admit(api, manifest, True)
    manifest['spec']['initContainers'][0]['image'] = 'busybox:latest'
    admit(api, manifest, False)
    manifest = pod()
    manifest['spec']['volumes'] = [{'name': 'image', 'image': {'reference': OWN}}]
    admit(api, manifest, True)
    manifest['spec']['volumes'][0]['image']['reference'] = 'busybox:latest'
    admit(api, manifest, False)


def test_pod_update_and_ephemeral_debug_subresource(api):
    result = api('create', '-f', '-', body=json.dumps(pod()))
    assert result.returncode == 0, result.stderr
    existing = json.loads(api('-n', 'default', 'get', 'pod', 'admission-test', '-o', 'json').stdout)
    try:
        updated = copy.deepcopy(existing)
        updated['spec']['containers'][0]['image'] = 'nginx:latest'
        result = api('replace', '--dry-run=server', '-f', '-', body=json.dumps(updated))
        assert result.returncode != 0 and 'platform-image-registry' in result.stderr, result.stderr
        for image, expected in [(OWN, True), ('busybox:latest', False), (AWS, False)]:
            updated = copy.deepcopy(existing)
            updated['spec']['ephemeralContainers'] = [{'name': 'debug', 'image': image}]
            result = api('replace', '--dry-run=server', '--raw',
                         '/api/v1/namespaces/default/pods/admission-test/ephemeralcontainers?dryRun=All',
                         '-f', '-', body=json.dumps(updated))
            assert (result.returncode == 0) == expected, result.stdout+result.stderr
    finally:
        api('-n', 'default', 'delete', 'pod', 'admission-test', '--wait=false')
