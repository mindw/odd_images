#!/usr/bin/env bash
# RUN using shared_assets credentials! - AWS_PROFILE=shared_assets
set -Eeuo pipefail

[[ -v DEBUG_SCRIPT ]] && set -x

DOCKER_IMAGE=$1
DOCKER_TAG=$2
NEW_TAG=${3:-latest}
ECR_REPOSITORY_SUFFIX="dev"
ECR_REGISTRY="569129334545.dkr.ecr.us-east-1.amazonaws.com"
ECR_IMAGE=${ECR_REGISTRY}/${DOCKER_IMAGE}-${ECR_REPOSITORY_SUFFIX}:${DOCKER_TAG}
echo adding tag "${ECR_REGISTRY}/${DOCKER_IMAGE}-${ECR_REPOSITORY_SUFFIX}:${NEW_TAG}" to "${ECR_IMAGE}"
skopeo copy --multi-arch all "docker://${ECR_IMAGE}" "docker://${ECR_REGISTRY}/${DOCKER_IMAGE}-${ECR_REPOSITORY_SUFFIX}:${NEW_TAG}"
