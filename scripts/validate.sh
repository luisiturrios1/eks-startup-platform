#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python_bin=${PYTHON:-.venv/bin/python}
terraform fmt -check -recursive
for environment in dev staging prod; do "$python_bin" scripts/compile_services.py --environment "$environment" --check; done
"$python_bin" scripts/check_policy.py
"$python_bin" -m pytest -q tests
for root in bootstrap environments/{dev,staging,prod} kubernetes/{dev,staging,prod}; do
  terraform -chdir="$root" init -backend=false -input=false -lockfile=readonly
  terraform -chdir="$root" validate
 done
terraform -chdir=modules/platform init -backend=false -input=false
terraform -chdir=modules/platform test
helm lint charts/service
helm lint charts/platform
helm template test charts/service >/dev/null
helm template test charts/service --set migrationOnly=true >/dev/null
helm template test charts/platform >/dev/null

"$python_bin" scripts/check_chart_images.py
