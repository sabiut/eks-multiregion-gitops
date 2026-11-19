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
# ALLOW_OUT_OF_ORDER=1 turns failures into warnings. The workflow sets it only when the pull
# request carries the "rollback" label; the code owner approval is still required.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/stages.sh

base=${1:?usage: check-promotion.sh <base ref>}
failed=0

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
