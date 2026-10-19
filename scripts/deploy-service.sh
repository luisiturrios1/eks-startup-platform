#!/usr/bin/env bash
# Manual, explicitly authorized deployment only. Not called by CI.
set -euo pipefail
if [[ $# != 3 || $1 != --approved ]]; then
  echo 'Usage: deploy-service.sh --approved VALUES.json EXPECTED_CLUSTER_CONTEXT' >&2; exit 2
fi
values=$2
[[ $(kubectl config current-context) == "$3" ]] || { echo 'Wrong Kubernetes context' >&2; exit 1; }
name=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["name"])' "$values")
policy=$(kubectl get namespace "$name" -o 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}') || { echo 'Namespace missing: apply the approved Kubernetes-root namespace plan first.' >&2; exit 1; }
[[ "$policy" == restricted ]] || { echo 'Namespace must already enforce restricted Pod Security through the Kubernetes root.' >&2; exit 1; }
revision=$(date -u +%Y%m%d%H%M%S)
if ! helm status "$name" -n "$name" >/dev/null 2>&1; then
  helm upgrade --install "$name" charts/service -f "$values" --namespace "$name" --set prerequisitesOnly=true --wait --timeout 5m
fi
# Migration is a separate release, so existing application workloads remain running.
helm upgrade --install "$name-migration" charts/service -f "$values" --namespace "$name" --set migrationOnly=true --set-string "migrationId=$revision" --wait --wait-for-jobs --timeout 11m
helm upgrade --install "$name" charts/service -f "$values" --namespace "$name" --wait --timeout 10m
kubectl -n "$name" rollout status "deployment/$name" --timeout=10m
