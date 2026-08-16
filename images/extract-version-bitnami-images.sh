#!/usr/bin/env bash
set -Eeuo pipefail

[[ -v DEBUG_SCRIPT ]] && set -x

echoerr() { printf "%s\n" "$*" >&2; }

if [[ ! -v 1 ]]; then
    echoerr "Both Path to Dockerfile argument is required"
    exit 1
fi

DOCKER_FILE=$1
APP_PREFIX=${2:+"$2_"}
APP_VERSION=$(grep 'APP_VERSION=' "${DOCKER_FILE}" | cut -d'"' -f2)
IMAGE_REVISION=$(grep 'IMAGE_REVISION=' "${DOCKER_FILE}" | cut -d'"' -f2)
OS_FLAVOUR=$(grep 'OS_FLAVOUR=' "${DOCKER_FILE}" | cut -d'"' -f2)

echo ${APP_PREFIX}APP_VERSION="${APP_VERSION}"
echo ${APP_PREFIX}IMAGE_REVISION="${IMAGE_REVISION}"
echo ${APP_PREFIX}OS_FLAVOUR="${OS_FLAVOUR}"
echo ${APP_PREFIX}VERSION="v${APP_VERSION}-${OS_FLAVOUR}-r${IMAGE_REVISION}"
