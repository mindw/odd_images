#!/usr/bin/env bash
# RUN using shared_assets credentials! - AWS_PROFILE=shared_assets
set -Eeuo pipefail

[[ -v DEBUG_SCRIPT ]] && set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DOCKERFILE=$(realpath "${SCRIPT_DIR}/12/debian-12/Dockerfile")

exec "${SCRIPT_DIR}/../copy-image-sources-s3-bitnami-images.sh" "${DOCKERFILE}"
