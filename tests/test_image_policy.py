import subprocess
import json
import xml.etree.ElementTree as ET
from pathlib import Path
import yaml
ROOT=Path(__file__).resolve().parents[1]
def render(image):
    return subprocess.run([str(ROOT/'scripts/helm_postrender.py')],input='spec:\n  containers:\n  - image: '+image+'\n',text=True,capture_output=True)
def test_private_digest_required():
    assert render('nginx:latest').returncode!=0
    assert render('111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:latest').returncode!=0
    result=render('111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:@sha256:'+'a'*64)
    assert result.returncode==0 and ':@sha256' not in result.stdout


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
