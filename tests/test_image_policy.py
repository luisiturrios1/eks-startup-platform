import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def render(image):
    return subprocess.run([str(ROOT/'scripts/helm_postrender.py')],input='spec:\n  containers:\n  - image: '+image+'\n',text=True,capture_output=True)
def test_private_digest_required():
    assert render('nginx:latest').returncode!=0
    assert render('111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:latest').returncode!=0
    result=render('111111111111.dkr.ecr.us-east-1.amazonaws.com/platform:@sha256:'+'a'*64)
    assert result.returncode==0 and ':@sha256' not in result.stdout
