#!/usr/bin/env bash
# The promotion gate. Runs on every pull request as a required check.
#
# For each stage whose image tag the pull request changes, the new tag must be the one the
# stage before it already has on the base branch. So a version moves one stage per merged
# pull request: nothing reaches stg before dev's change is merged, and nothing reaches
# production before stg's is, whoever wrote the pull request and however.
#
# Limit: "merged" means Argo CD was told to run it, not that it ran well. Checking the
# rollout's health before promoting needs a view of the cluster, which this repository
# does not have on purpose. In production that check is a step in the promote workflow
# (query Argo CD or Prometheus) or an automated analysis in the rollout.
#
#   scripts/check-promotion.sh origin/main
#
# It also checks that release.yaml really is what gets deployed (part 1 below). Needs helm.
#
# ALLOW_OUT_OF_ORDER=1 turns order failures into warnings (never the part 1 failures). The workflow sets it only when the pull
# request carries the "rollback" label; the code owner approval is still required.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/stages.sh

base=${1:?usage: check-promotion.sh <base ref>}
failed=0

# ---- Part 1: the release file must be the only place a version can come from ----
# Helm merges several values files, and a later one wins. If a tag could also be set in a
# workload's settings file or in a cluster file, the order check below would be looking at
# one tag while the cluster ran another. So: no "tag:" key anywhere except release.yaml, and
# then the proof, by rendering each stage the way Argo CD does and reading the images.
# The same goes for the image repository: only the catalogue may set it.
key='(^|[{,[:space:]])"?KEY"?[[:space:]]*:'   # block style (tag: x) or flow style ({tag: x})
others=$( { grep -rnE "${key/KEY/tag}" envs clusters charts/platform-apps/values.yaml | grep -v '/release\.yaml:'
            grep -rnE "${key/KEY/repository}" envs clusters; } | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -n $others ]]; then
  echo "FAIL  an image tag or repository is set outside release.yaml and the catalogue:"
  echo "$others" | sed 's/^/        /'
  failed=1
fi

for stage in "${STAGES[@]}"; do
  file=$(stage_file "$stage")
  dir=$(dirname "$file")
  want=$(read_tag < "$file")
  for chart in demo-web demo-api; do
    images=$(helm template "$chart" "charts/$chart" -f "$dir/release.yaml" -f "$dir/$chart.yaml" \
               --set image.repository="$chart" --set "networkPolicy.ingressCIDRs={10.0.0.0/16}" \
             | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' | sort -u)
    if [[ $images != "$chart:$want" ]]; then
      echo "FAIL  $stage: $chart would run [$(echo $images)], but release.yaml says $want"
      failed=1
    fi
  done
done
[[ $failed == 0 ]] && echo "OK    every stage runs exactly the tag in its release.yaml"

# ---- Part 2: the promotion order ----

for stage in "${STAGES[@]}"; do
  file=$(stage_file "$stage")
  old=$(git show "$base:$file" 2>/dev/null | read_tag || true)
  new=$(read_tag < "$file")
  [[ $old == "$new" ]] && continue

  from=$(stage_source "$stage")
  if [[ -z $from ]]; then
    echo "OK    $stage: $old -> $new (a new build)"
    continue
  fi
  # What the stage before is running comes from the BASE branch (what is merged and so
  # deployed), not from this pull request. Otherwise one pull request could change every
  # stage to the same new tag and each change would vouch for the next.
  expected=$(git show "$base:$(stage_file "$from")" 2>/dev/null | read_tag || true)
  if [[ $new == "$expected" ]]; then
    echo "OK    $stage: $old -> $new (the version $from is running)"
  elif [[ ${ALLOW_OUT_OF_ORDER:-0} == 1 ]]; then
    echo "WARN  $stage: $old -> $new, but $from is running $expected (allowed: rollback label)"
  else
    echo "FAIL  $stage: $old -> $new, but $from is running $expected. Promote through $from first."
    failed=1
  fi
done

[[ $failed == 0 ]] || exit 1
echo "Promotion order respected."
