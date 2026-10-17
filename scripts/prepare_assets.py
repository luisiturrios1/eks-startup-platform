#!/usr/bin/env python3
"""Reuse verified assets and retry transient downloads without relaxing checksums."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / '.artifacts'
SOURCES = {
    'calico.yaml': 'https://raw.githubusercontent.com/projectcalico/calico/v3.30.3/manifests/calico.yaml',
    'global-bundle.pem': 'https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem',
    'cert-manager-v1.21.2.tgz': ['helm', 'pull', 'cert-manager', '--repo', 'https://charts.jetstack.io', '--version', 'v1.21.2'],
    'karpenter-1.15.0.tgz': ['helm', 'pull', 'oci://public.ecr.aws/karpenter/karpenter', '--version', '1.15.0'],
    'aws-load-balancer-controller-3.6.0.tgz': ['helm', 'pull', 'aws-load-balancer-controller', '--repo', 'https://aws.github.io/eks-charts', '--version', '3.6.0'],
    'metrics-server-3.13.0.tgz': ['helm', 'pull', 'metrics-server', '--repo', 'https://kubernetes-sigs.github.io/metrics-server', '--version', '3.13.0'],
}


def verify(path, digest):
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError('Artifact checksum mismatch; review source before updating lock: ' + path.name)


def prepare_asset(name, digest, source, download=None, sleep=time.sleep):
    target = ARTIFACTS / name
    if target.exists():
        verify(target, digest)
        return
    with tempfile.TemporaryDirectory(dir=ARTIFACTS) as temporary:
        stage = Path(temporary) / name
        for attempt in range(5):
            try:
                if download:
                    download(stage)
                elif isinstance(source, str):
                    with urllib.request.urlopen(source, timeout=30) as response, stage.open('wb') as output:
                        shutil.copyfileobj(response, output)
                else:
                    subprocess.run(source + ['--destination', temporary], check=True, timeout=60)
                break
            except (OSError, subprocess.SubprocessError) as error:
                if attempt == 4:
                    raise
                print(f'{name}: transient download failure ({type(error).__name__}); retry {attempt + 1}/4', flush=True)
                sleep(min(2 ** (attempt + 1), 30))
        # Integrity failures never trigger a retry, fallback or replacement of the lock.
        verify(stage, digest)
        stage.replace(target)


def main():
    ARTIFACTS.mkdir(exist_ok=True)
    lock = json.loads((ROOT/'config/artifacts.lock.json').read_text())
    if set(lock) != set(SOURCES):
        raise ValueError('Artifact source list and reviewed lock must match')
    for name, digest in lock.items():
        prepare_asset(name, digest, SOURCES[name])
    bundle = ARTIFACTS/'global-bundle.pem'
    pkcs = subprocess.check_output(['openssl', 'crl2pkcs7', '-nocrl', '-certfile', str(bundle)])
    subjects = subprocess.check_output(['openssl', 'pkcs7', '-print_certs', '-noout'], input=pkcs)
    (ARTIFACTS/'rds-ca-subjects.txt').write_bytes(subjects)
    for directory in ['examples/apps', 'components/credential-manager']:
        shutil.copyfile(bundle, ROOT/directory/'global-bundle.pem')
    print('Artifact checksums verified; cached assets reused where available')


if __name__ == '__main__':
    main()
