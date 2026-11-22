#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -euo pipefail

: "${IMAGE:?IMAGE is required}"
: "${TAG:?TAG is required}"

image=$(printf '%s' "$IMAGE" | tr '[:upper:]' '[:lower:]')
tag=$(printf '%s' "$TAG" |
  tr '[:upper:]' '[:lower:]' |
  sed -E 's/[^a-z0-9_.-]+/-/g; s/^[.-]+//')
tag=${tag:0:128}
[[ $tag =~ ^[a-z0-9_][a-z0-9_.-]{0,127}$ ]] || {
  echo "build-image: TAG does not sanitize to a valid Docker tag" >&2
  exit 1
}

push=${PUSH:-0}
version_tag=${VERSION_TAG:-0}
[[ $push == 0 || $push == 1 ]] || {
  echo "build-image: PUSH must be 0 or 1" >&2
  exit 1
}
[[ $version_tag == 0 || $version_tag == 1 ]] || {
  echo "build-image: VERSION_TAG must be 0 or 1" >&2
  exit 1
}

image_ref="${image}:${tag}"
build_args=(--pull -f ci/arc/Dockerfile.actions-runner -t "$image_ref")
if [[ -n ${SOURCE_URL:-} ]]; then
  build_args+=(--label "org.opencontainers.image.source=${SOURCE_URL}")
fi
docker build "${build_args[@]}" ci/arc

docker run --rm --entrypoint /bin/bash "$image_ref" -lc '
set -euo pipefail
[[ "$(id -u)" == 1001 ]]
[[ "$(id -g)" == 1001 ]]
if sudo -n true; then
  echo "build-image: sudo -n true unexpectedly succeeded" >&2
  exit 1
fi
'

docker run --rm --user 1001:1001 --cap-drop ALL \
  --security-opt no-new-privileges --entrypoint /bin/bash "$image_ref" -lc '
set -euo pipefail
for tool in j2 jq curl unzip git ssh-keygen; do
  command -v "$tool"
done
printf "{{ FOO }}\n" > t.j2
rendered=$(FOO=ok j2 t.j2)
[[ $rendered == ok ]]
printf "%s\n" "$rendered"
'

runner_version_output=$(docker run --rm --user 1001:1001 --cap-drop ALL \
  --security-opt no-new-privileges --entrypoint /bin/bash "$image_ref" -lc \
  '/home/runner/bin/Runner.Listener --version')
printf '%s\n' "$runner_version_output"
runner_version=$(
  printf '%s\n' "$runner_version_output" |
    grep -Ex '[0-9]+\.[0-9]+\.[0-9]+' | tail -n1
)
[[ -n $runner_version ]] || {
  echo "build-image: could not determine the runner version" >&2
  exit 1
}
printf 'runner version: %s\n' "$runner_version"

version_ref=''
if [[ $version_tag == 1 ]]; then
  version_ref="${image}:${runner_version}"
  if [[ $version_ref != "$image_ref" ]]; then
    docker tag "$image_ref" "$version_ref"
  fi
fi

if [[ $push == 1 ]]; then
  push_image() {
    local ref=$1 output digest
    if ! output=$(docker push "$ref" 2>&1); then
      printf '%s\n' "$output" >&2
      return 1
    fi
    printf '%s\n' "$output"
    digest=$(printf '%s\n' "$output" | grep -Eo 'sha256:[0-9a-f]{64}' | tail -n1)
    [[ -n $digest ]] || {
      echo "build-image: docker push did not report a digest for $ref" >&2
      return 1
    }
    printf 'pushed digest for %s: %s\n' "$ref" "$digest"
  }

  push_image "$image_ref"
  if [[ $version_tag == 1 && $version_ref != "$image_ref" ]]; then
    push_image "$version_ref"
  fi
else
  echo "PUSH=0: image left local as $image_ref"
fi
