#!/usr/bin/env bash
set -e

[[ -v DEBUG_SCRIPT ]] && set -x

SCRIPT_DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

cd "${SCRIPT_DIR}/current/debian-12"
source ./version.sh
"${SCRIPT_DIR}/../../build-utils/docker-build-and-push-to-ecr.sh" "$@" -s dev -f Dockerfile bitnami/rabbitmq "${RABBITMQ_VERSION}"
