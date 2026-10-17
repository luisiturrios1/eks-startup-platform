#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .artifacts
curl --fail --show-error --silent --proto "=https" https://raw.githubusercontent.com/projectcalico/calico/v3.30.3/manifests/calico.yaml -o .artifacts/calico.yaml
helm pull cert-manager --repo https://charts.jetstack.io --version v1.21.2 --destination .artifacts
helm pull oci://public.ecr.aws/karpenter/karpenter --version 1.15.0 --destination .artifacts
helm pull aws-load-balancer-controller --repo https://aws.github.io/eks-charts --version 3.6.0 --destination .artifacts
helm pull metrics-server --repo https://kubernetes-sigs.github.io/metrics-server --version 3.13.0 --destination .artifacts
curl --fail --show-error --silent --proto '=https' --tlsv1.2 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o .artifacts/global-bundle.pem
openssl crl2pkcs7 -nocrl -certfile .artifacts/global-bundle.pem | openssl pkcs7 -print_certs -noout > .artifacts/rds-ca-subjects.txt
cp .artifacts/global-bundle.pem examples/apps/global-bundle.pem
cp .artifacts/global-bundle.pem components/credential-manager/global-bundle.pem
python3 - <<'PY'
from pathlib import Path
import hashlib,json
p=Path('.artifacts')
print(json.dumps({x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in p.iterdir() if x.is_file()},indent=2))
PY
python3 - <<'PY'
from pathlib import Path
import hashlib,json
for name,digest in json.loads(Path('config/artifacts.lock.json').read_text()).items():
    if hashlib.sha256((Path('.artifacts')/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Artifact checksum changed; review before updating lock: '+name)
print('Artifact checksums verified')
PY
