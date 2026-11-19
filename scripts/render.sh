#!/usr/bin/env bash
# Render everything Argo CD would apply to a cluster, without a cluster. Used by the pipeline
# to catch a broken chart or values file before it is merged.
#
#   scripts/render.sh ap-southeast-2        # print
#   scripts/render.sh all                   # check every cluster, print a summary
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# Stand-ins for the facts Ansible passes from Terraform's outputs.
facts=(--set repoURL=https://example.invalid/gitops.git --set clusterDir=__DIR__
  --set cluster.name=lab-__DIR__ --set cluster.region=__DIR__ --set-string cluster.accountId=000000000000
  --set cluster.registry=000000000000.dkr.ecr.__DIR__.amazonaws.com --set cluster.vpcCidr=10.40.0.0/16
  --set cluster.karpenterQueue=lab-__DIR__ --set cluster.karpenterNodeRole=lab-__DIR__-karpenter-node
  --set cluster.veleroBucket=lab-__DIR__-velero-000000000000 --set cluster.vaultKmsAlias=alias/lab-__DIR__-vault-unseal)

render() {
  local dir=$1 args=()
  for f in "${facts[@]}"; do args+=("${f//__DIR__/$dir}"); done
  [[ $dir == local ]] && args+=(--set cluster.registry= --set cluster.vaultKmsAlias=)
  echo "# ===== Applications for $dir ====="
  helm template root charts/platform-apps -f "clusters/$dir/platform.yaml" "${args[@]}"
  # Both tiers of the application, once per environment this cluster hosts.
  local line env ns envdir chart
  while read -r line; do
    env=${line%%:*}
    ns=$(sed -n 's/.*namespace: *\([^,}]*\).*/\1/p' <<<"$line")
    envdir=$(sed -n 's/.*dir: *\([^,}]*\).*/\1/p' <<<"$line")
    for chart in demo-web demo-api; do
      echo "# ===== $chart, environment $env ($envdir) ====="
      helm template "$chart" "charts/$chart" -n "$ns" -f "$envdir/release.yaml" -f "$envdir/$chart.yaml" \
        --set image.repository="$chart" --set environment="$env" --set "networkPolicy.ingressCIDRs={10.40.0.0/16}"
    done
  done < <(sed -n '/^environments:/,$p' "clusters/$dir/platform.yaml" | grep -E '^  [a-z]+: *\{' | sed 's/^  //')
  echo "# ===== platform-config for $dir ====="
  helm template platform-config charts/platform-config \
    --set cluster.name="lab-$dir" --set cluster.karpenterNodeRole="lab-$dir-karpenter-node" \
    --set karpenter.enabled=true --set storageClass.enabled=true \
    --set namespaces.demo.podSecurity=restricted
}

if [[ ${1:-all} == all ]]; then
  for d in clusters/*/; do
    d=$(basename "$d")
    out=$(render "$d")
    echo "$d: $(grep -c '^kind:' <<<"$out") objects, $(grep -c '^kind: Application$' <<<"$out") Applications"
  done
else
  render "$1"
fi
