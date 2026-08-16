#!/usr/bin/env bash
set -e

[[ -v DEBUG_SCRIPT ]] && set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

cd "${SCRIPT_DIR}/12/debian-12"
source ./version.sh
"${SCRIPT_DIR}/../../build-utils/docker-build-and-push-to-ecr.sh" "$@" -s dev -f Dockerfile bitnami/os-shell "${OS_SHELL_VERSION}"
