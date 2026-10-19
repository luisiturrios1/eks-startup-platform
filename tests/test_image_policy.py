import subprocess
import json
import xml.etree.ElementTree as ET
from pathlib import Path
import yaml
import pytest
ROOT=Path(__file__).resolve().parents[1]
def render(image):
    return subprocess.run([str(ROOT/'scripts/helm_postrender.py'), '--registry', '111111111111.dkr.ecr.us-east-1.amazonaws.com'],input='spec:\n  containers:\n  - image: '+image+'\n',text=True,capture_output=True)
def test_private_digest_required():
    assert render('nginx:latest').returncode!=0
    assert render('111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:latest').returncode!=0
    result=render('111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:@sha256:'+'a'*64)
    assert result.returncode==0 and ':@sha256' not in result.stdout
    tagged=render('111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:v1.2.3@sha256:'+'a'*64)
    assert tagged.returncode==0 and ':v1.2.3@' not in tagged.stdout


def test_java_26_build_and_runtime_contract():
    dockerfile = (ROOT/'examples/apps/Dockerfile').read_text()
    bases = [line for line in dockerfile.splitlines() if line.startswith('FROM ')]
    assert len(bases) == 2
    assert '-eclipse-temurin-26@sha256:' in bases[0]
    assert bases[1].startswith('FROM eclipse-temurin:26-jre@sha256:')
    images = json.loads((ROOT/'config/images.lock.json').read_text())
    for base, key in zip(bases, ('maven', 'java')):
        assert base.split()[1] == images[key]['source']+'@'+images[key]['digest']
    pom = ET.parse(ROOT/'examples/apps/pom.xml')
    assert pom.findtext('{*}properties/{*}java.version') == '26'
    workflow = yaml.safe_load((ROOT/'.github/workflows/validate.yaml').read_text())
    java_steps = [step for job in workflow['jobs'].values() for step in job['steps']
                  if step.get('uses', '').startswith('actions/setup-java@')]
    assert java_steps
    assert all(str(step['with']['java-version']) == '26' for step in java_steps)


@pytest.mark.parametrize('image', [
    '222222222222.dkr.ecr.us-east-1.amazonaws.com/platform@sha256:'+'a'*64,
    '111111111111.dkr.ecr.us-west-2.amazonaws.com/platform@sha256:'+'a'*64,
    '111111111111.dkr.ecr.us-east-1.amazonaws.com.attacker.invalid/platform@sha256:'+'a'*64,
    'public.ecr.aws/example/platform@sha256:'+'a'*64,
    '111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:latest',
])
def test_foreign_registry_and_mutable_images_rejected(image):
    assert render(image).returncode != 0


def test_inline_hook_and_init_images_are_checked():
    manifest = '''apiVersion: batch/v1
kind: Job
metadata: {name: hook, annotations: {helm.sh/hook: pre-install}}
spec:
  template:
    spec:
      containers: [{name: hook, image: "111111111111.dkr.ecr.us-east-1.amazonaws.com/platform@sha256:'''+'a'*64+'''"}]
      initContainers: [{name: init, image: "docker.io/library/busybox:latest"}]
'''
    result = subprocess.run([str(ROOT/'scripts/helm_postrender.py'), '--registry',
                             '111111111111.dkr.ecr.us-east-1.amazonaws.com'],
                            input=manifest, text=True, capture_output=True)
    assert result.returncode != 0
    assert 'busybox' in result.stderr
