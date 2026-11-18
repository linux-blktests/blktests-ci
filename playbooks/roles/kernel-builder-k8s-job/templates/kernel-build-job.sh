#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -euo pipefail

: "${KERNEL_TREE:?KERNEL_TREE is required}"
: "${KERNEL_REF:?KERNEL_REF is required}"

KERNEL_TAG_OVERWRITE="${KERNEL_TAG_OVERWRITE:-}"
BASE_CONTAINERDISK_IMAGE="${BASE_CONTAINERDISK_IMAGE:-ghcr.io/linux-nvme/blktests-fedora-containerdisk:latest}"
KERNEL_IMAGE_REGISTRY_URL="${KERNEL_IMAGE_REGISTRY_URL:-http://registry-service.docker-registry.svc.cluster.local}"
KERNEL_IMAGE_REPOSITORY="${KERNEL_IMAGE_REPOSITORY:-linux-kernel-containerdisk}"
BUILD_ROOT="${BUILD_ROOT:-/work}"
MAKE_JOBS="${MAKE_JOBS:-}"
TERMINATION_LOG="${TERMINATION_LOG:-/dev/termination-log}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z $MAKE_JOBS ]]; then
  MAKE_JOBS=$(nproc) || {
    printf 'error: could not determine the available CPU count\n' >&2
    exit 1
  }
  if [[ ${KERNEL_BUILD_MEMORY_LIMIT_GIB:-} =~ ^[1-9][0-9]*$ ]] &&
     (( MAKE_JOBS > KERNEL_BUILD_MEMORY_LIMIT_GIB )); then
    MAKE_JOBS=$KERNEL_BUILD_MEMORY_LIMIT_GIB
  fi
fi
export MAKE_JOBS
printf 'kernel-build-job: MAKE_JOBS=%s\n' "$MAKE_JOBS"

# shellcheck source=.github/actions/kubevirt-action/registry.sh
source "${script_dir}/registry.sh"

publish_kernel_digest() (
  set +x
  if (( $# < 3 || $# > 5 )); then
    printf 'error: invalid arguments to publish_kernel_digest\n' >&2
    exit 2
  fi

  local configmap=$1 key=$2 digest=$3
  local sa_dir=${4:-/var/run/secrets/kubernetes.io/serviceaccount}
  local api_url=${5:-https://kubernetes.default.svc}
  local namespace token patch curl_dir curl_config url

  if [[ ! -r $sa_dir/token || ! -r $sa_dir/namespace || ! -r $sa_dir/ca.crt ]]; then
    printf 'error: service account credentials are unavailable\n' >&2
    exit 1
  fi
  namespace=$(<"$sa_dir/namespace")
  token=$(<"$sa_dir/token")
  if [[ -z $namespace || -z $token ]]; then
    printf 'error: service account namespace or token is empty\n' >&2
    exit 1
  fi
  patch=$(jq -cn --arg key "$key" --arg digest "$digest" '{data:{($key):$digest}}') || exit 1
  curl_dir=$(mktemp -d) || exit 1
  trap 'rm -rf -- "$curl_dir"' EXIT
  chmod 700 "$curl_dir" || exit 1
  curl_config="${curl_dir}/curl.conf"
  (umask 077; printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_config") || exit 1
  chmod 600 "$curl_config" || exit 1
  unset token
  url="${api_url%/}/api/v1/namespaces/${namespace}/configmaps/${configmap}"

  curl --fail --silent --show-error \
    -K "$curl_config" \
    --cacert "$sa_dir/ca.crt" \
    -H 'Content-Type: application/merge-patch+json' \
    -X PATCH \
    --data-binary "$patch" \
    "$url" >/dev/null
)

export KERNEL_TREE KERNEL_REF KERNEL_TAG_OVERWRITE BUILD_ROOT MAKE_JOBS
export TMPDIR="${BUILD_ROOT}/tmp"
export HOME="${BUILD_ROOT}/home"
export LIBGUESTFS_CACHEDIR="${BUILD_ROOT}/libguestfs"

mkdir -p "$TMPDIR" "$HOME" "$LIBGUESTFS_CACHEDIR" \
  "${BUILD_ROOT}/base-disk" "${BUILD_ROOT}/output" "${BUILD_ROOT}/version"

base_ref=$(registry_parse_ref "$BASE_CONTAINERDISK_IMAGE") || exit 1
read -r base_registry base_repository base_reference <<< "$base_ref"
registry_extract "$base_registry" "$base_repository" "$base_reference" \
  "${BUILD_ROOT}/base-containerdisk" disk

shopt -s nullglob dotglob
base_disks=("${BUILD_ROOT}"/base-containerdisk/disk/*)
(( ${#base_disks[@]} > 0 )) || {
  printf 'error: base containerdisk has no files under /disk\n' >&2
  exit 1
}
for disk in "${base_disks[@]}"; do
  [[ -f $disk ]] || continue
  mv -- "$disk" "${BUILD_ROOT}/base-disk/"
done
[[ -n $(find "${BUILD_ROOT}/base-disk" -maxdepth 1 -type f -print -quit) ]] || {
  printf 'error: no disk image found in base containerdisk\n' >&2
  exit 1
}

cd "$script_dir"
bash "${script_dir}/get-base-kernel-artifacts.sh"
bash "${script_dir}/build-kernel.sh"

# shellcheck disable=SC1091
source "${BUILD_ROOT}/version/tag"
[[ ${KERNEL_VERSION:-} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || {
  printf 'error: invalid KERNEL_VERSION: %s\n' "${KERNEL_VERSION:-missing}" >&2
  exit 1
}

kernel_image_digest=$(registry_push_boot_image "$KERNEL_IMAGE_REGISTRY_URL" \
  "$KERNEL_IMAGE_REPOSITORY" "$KERNEL_VERSION" "${BUILD_ROOT}/output") || exit 1

if [[ -n ${KERNEL_DIGEST_CONFIGMAP:-} ]]; then
  if ! publish_kernel_digest "$KERNEL_DIGEST_CONFIGMAP" "$KERNEL_VERSION" "$kernel_image_digest"; then
    printf 'error: could not publish the kernel digest\n' >&2
    exit 1
  fi
fi

printf 'kernel-build-result: KERNEL_VERSION=%s\n' "$KERNEL_VERSION"
printf 'kernel-build-result: KERNEL_IMAGE_DIGEST=%s\n' "$kernel_image_digest"
if ! {
  printf 'KERNEL_VERSION=%s\n' "$KERNEL_VERSION"
  printf 'KERNEL_IMAGE_DIGEST=%s\n' "$kernel_image_digest"
} > "$TERMINATION_LOG"; then
  printf 'warning: could not write build results to %s\n' "$TERMINATION_LOG" >&2
fi
