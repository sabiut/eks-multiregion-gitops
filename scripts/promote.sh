#!/usr/bin/env bash
# Move a version one step along dev -> stg -> prd Sydney -> prd Singapore.
# It only edits one line in one file (the environment's release.yaml). The promote workflow runs it and opens a pull request.
#
#   scripts/promote.sh dev a1b2c3d            # a new build enters dev
#   scripts/promote.sh stg                    # stg takes the version dev is running
#   scripts/promote.sh prd-ap-southeast-2     # production (Sydney) takes the version stg is running
#   scripts/promote.sh prd-ap-southeast-1     # Singapore takes the version Sydney is running
#   scripts/promote.sh status                 # what each stage is running
#
# There is no way to name a tag for stg or prd: a version can only arrive from the stage
# before it. A rollback is `git revert` of the promotion commit, through a pull request.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/stages.sh

to=${1:?usage: promote.sh <dev <tag>|stg|prd-ap-southeast-2|prd-ap-southeast-1|status>}

if [[ $to == status ]]; then
  for s in "${STAGES[@]}"; do printf '%-20s %s\n' "$s" "$(read_tag < "$(stage_file "$s")")"; done
  exit 0
fi

file=$(stage_file "$to")
from=$(stage_source "$to")
if [[ -z $from ]]; then
  tag=${2:?dev needs the image tag from the build}
  [[ $tag =~ ^[0-9a-f]{7,40}$ ]] || { echo "not a commit tag: $tag" >&2; exit 1; }
else
  [[ $# -eq 1 ]] || { echo "$to takes its version from $from; a tag cannot be given" >&2; exit 1; }
  tag=$(read_tag < "$(stage_file "$from")")
fi

current=$(read_tag < "$file")
if [[ $current == "$tag" ]]; then
  echo "$to already runs $tag"
  exit 0
fi
sed -i "s|^  tag: .*|  tag: \"$tag\"|" "$file"
echo "$to: $current -> $tag  ($file)"
