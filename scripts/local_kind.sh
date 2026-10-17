#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/.artifacts/bin:$PATH"
kind get clusters | grep -qx platform-local || kind create cluster --config local/kind.yaml --image kindest/node:v1.34.0
context=kind-platform-local
python3 - <<'PYTHON'
from pathlib import Path
s=Path('.artifacts/calico.yaml').read_text().replace('# - name: CALICO_IPV4POOL_CIDR','- name: CALICO_IPV4POOL_CIDR').replace('#   value: "192.168.0.0/16"','  value: "10.244.0.0/16"')
Path('.artifacts/calico-local.yaml').write_text(s)
PYTHON
kubectl --context "$context" apply -f .artifacts/calico-local.yaml
kubectl --context "$context" -n kube-system rollout status daemonset/calico-node --timeout=180s
docker build -t platform-examples:local examples/apps
kind load docker-image --name platform-local platform-examples:local
for service in payments-service auth-service; do
 kubectl --context "$context" -n "$service" delete job migrate --ignore-not-found=true 2>/dev/null || true
done
.venv/bin/python scripts/connect_local_network.py
.venv/bin/python scripts/local_manifest.py --stage migrations > .artifacts/local-migrations.yaml
kubectl --context "$context" apply -f .artifacts/local-migrations.yaml
for service in payments-service auth-service; do
  kubectl --context "$context" -n "$service" wait --for=condition=complete job/migrate --timeout=180s
done
.venv/bin/python scripts/local_manifest.py --stage runtime > .artifacts/local-services.yaml
kubectl --context "$context" apply -f .artifacts/local-services.yaml
for service in payments-service auth-service; do
  kubectl --context "$context" -n "$service" rollout status deployment/"$service" --timeout=180s
done
