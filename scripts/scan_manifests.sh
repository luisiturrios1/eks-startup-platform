#!/usr/bin/env bash
# Scan resolved objects so Go templates cannot hide Kubernetes findings.
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root=$PWD
trivy_bin=${TRIVY:-$repo_root/.artifacts/bin/trivy}
render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT
for chart in platform system-network; do
  helm template "$chart" "charts/$chart" --output-dir "$render_dir/charts" >/dev/null
done
# Keep the single-resource Fluent Bit exception path identical to its source path.
mv "$render_dir/charts/platform-configuration" "$render_dir/charts/platform"
helm template service charts/service --set production=true --output-dir "$render_dir/charts" >/dev/null
helm template migration charts/service --set migrationOnly=true --output-dir "$render_dir/migration" >/dev/null
"$trivy_bin" config --ignorefile "$repo_root/.trivyignore.yaml" --exit-code 1 --severity HIGH,CRITICAL "$render_dir"
