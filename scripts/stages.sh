# The promotion order, in one place. Sourced by promote.sh and check-promotion.sh.
#
#   stage                 values file                              gets its version from
#   dev                   envs/dev/release.yaml                    the build (a new image tag)
#   stg                   envs/stg/release.yaml                    dev
#   prd-ap-southeast-2    envs/prd/ap-southeast-2/release.yaml     stg
#   prd-ap-southeast-1    envs/prd/ap-southeast-1/release.yaml     prd-ap-southeast-2
STAGES=(dev stg prd-ap-southeast-2 prd-ap-southeast-1)

stage_file() {
  case $1 in
    dev)   echo envs/dev/release.yaml ;;
    stg)   echo envs/stg/release.yaml ;;
    prd-*) echo "envs/prd/${1#prd-}/release.yaml" ;;
    *)     echo "unknown stage: $1" >&2; return 1 ;;
  esac
}

# The stage a stage is promoted from. Empty for dev.
stage_source() {
  case $1 in
    dev)                echo "" ;;
    stg)                echo dev ;;
    prd-ap-southeast-2) echo stg ;;
    prd-ap-southeast-1) echo prd-ap-southeast-2 ;;
    *)                  echo "unknown stage: $1" >&2; return 1 ;;
  esac
}

# Read image.tag from a values file on stdin.
read_tag() {
  sed -n 's/^  tag: *"\{0,1\}\([^"#[:space:]]*\)"\{0,1\}.*/\1/p' | head -n 1
}
