#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -euo pipefail

fail() {
  printf 'kernel-build-action: %s\n' "$*" >&2
  exit 1
}

action_dir="${GITHUB_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
repository_root="$(cd "${action_dir}/../../.." && pwd)"
template_dir="${repository_root}/playbooks/roles/kernel-builder-k8s-job/templates"
build_temp_dir=''

cleanup_build_temp_dir() {
  if [[ -n $build_temp_dir ]]; then
    rm -rf -- "$build_temp_dir"
  fi
}

trap cleanup_build_temp_dir EXIT

get_build_namespace() {
  if [[ -n ${KERNEL_BUILD_NAMESPACE:-} ]]; then
    printf '%s\n' "$KERNEL_BUILD_NAMESPACE"
    return
  fi
  local namespace_file=/var/run/secrets/kubernetes.io/serviceaccount/namespace
  [[ -r $namespace_file ]] || fail "cannot determine the runner namespace"
  local namespace
  namespace=$(<"$namespace_file")
  [[ -n $namespace ]] || fail "runner namespace file is empty"
  printf '%s-build\n' "$namespace"
}

runner_architecture() {
  local machine
  machine=$(uname -m) || fail "could not determine the runner architecture"
  case "$machine" in
    x86_64) printf 'amd64\n' ;;
    aarch64) printf 'arm64\n' ;;
    ppc64le) printf 'ppc64le\n' ;;
    *) printf '%s\n' "$machine" ;;
  esac
}

diagnostics() {
  local job_name=$1 namespace=$2 pod_name=${3:-}
  printf '===== kernel build diagnostics: %s/%s =====\n' "$namespace" "$job_name" >&2
  kubectl describe job "$job_name" -n "$namespace" >&2 || true
  if [[ -n $pod_name ]]; then
    kubectl describe pod "$pod_name" -n "$namespace" >&2 || true
    kubectl get pod "$pod_name" -n "$namespace" -o json |
      jq -r '"pod reason: \(.status.reason // "none")", (.status.containerStatuses[]? | "container termination reason: \(.state.terminated.reason // .state.waiting.reason // "running")")' >&2 || true
  else
    kubectl describe pods -n "$namespace" \
      -l "batch.kubernetes.io/job-name=${job_name}" >&2 || true
  fi
  kubectl get events -n "$namespace" --sort-by=.metadata.creationTimestamp >&2 || true
}

verify_job_uid() {
  local job_name=$1 namespace=$2 expected_uid=$3 job_json current_uid
  job_json=$(kubectl get job "$job_name" -n "$namespace" -o json 2>/dev/null) ||
    fail "kernel build Job was replaced"
  current_uid=$(jq -r '.metadata.uid // empty' <<< "$job_json") ||
    fail "could not read kernel build Job UID"
  [[ $current_uid == "$expected_uid" ]] || fail "kernel build Job was replaced"
}

lookup_job_pod() {
  local job_name=$1 namespace=$2 expected_uid=$3 pod_list
  KERNEL_BUILD_POD_NAME=''
  KERNEL_BUILD_POD_JSON=''
  pod_list=$(kubectl get pods -n "$namespace" \
    -l "batch.kubernetes.io/job-name=${job_name}" -o json) ||
    fail "could not list kernel build pods"
  KERNEL_BUILD_POD_NAME=$(jq -r '.items[0].metadata.name // empty' <<< "$pod_list") ||
    fail "could not read kernel build pod name"
  if [[ -z $KERNEL_BUILD_POD_NAME ]]; then
    pod_list=$(kubectl get pods -n "$namespace" -l "job-name=${job_name}" -o json) ||
      fail "could not list kernel build pods"
    KERNEL_BUILD_POD_NAME=$(jq -r '.items[0].metadata.name // empty' <<< "$pod_list") ||
      fail "could not read kernel build pod name"
  fi
  [[ -n $KERNEL_BUILD_POD_NAME ]] || return 0
  KERNEL_BUILD_POD_JSON=$(kubectl get pod "$KERNEL_BUILD_POD_NAME" \
    -n "$namespace" -o json) || fail "kernel build Job was replaced"
  jq -e --arg uid "$expected_uid" --arg job_name "$job_name" \
    'any(.metadata.ownerReferences[]?; .uid == $uid and .kind == "Job" and .name == $job_name)' \
    <<< "$KERNEL_BUILD_POD_JSON" >/dev/null ||
    fail "kernel build Job was replaced"
}

extract_result_value() {
  local text=$1 key=$2 value
  value=$(awk -v key="$key" '
    {
      sub(/^kernel-build-result: /, "")
      if (index($0, key "=") == 1) {
        value = substr($0, length(key) + 2)
      }
    }
    END {
      if (value != "") {
        print value
      }
    }
  ' <<< "$text") || return 1
  printf '%s\n' "$value"
}

build() {
  : "${INPUT_KERNEL_TREE:?kernel_tree input is required}"
  : "${INPUT_KERNEL_REF:?kernel_ref input is required}"
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v j2 >/dev/null 2>&1 || fail "j2 is required"
  command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"

  local run_id=${GITHUB_RUN_ID:-0}
  local run_attempt=${GITHUB_RUN_ATTEMPT:-1}
  local random_suffix base_name max_base job_name namespace builder_image deadline architecture
  random_suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  [[ $random_suffix =~ ^[0-9a-f]{8}$ ]] || fail "could not generate a job name suffix"
  base_name="kbuild-${run_id}-${run_attempt}"
  base_name=$(printf '%s' "$base_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  max_base=$((52 - ${#random_suffix} - 1))
  base_name="${base_name:0:max_base}"
  base_name="${base_name%-}"
  job_name="${base_name}-${random_suffix}"
  [[ $job_name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#job_name} -le 52 ]] ||
    fail "generated invalid Job name: ${job_name}"
  namespace=$(get_build_namespace)
  architecture=$(runner_architecture)
  printf 'job_name=%s\n' "$job_name" >> "$GITHUB_OUTPUT"

  builder_image="${KERNEL_BUILDER_IMAGE:-container-registry.local:5000/linux-kernel-builder:latest}"
  deadline="${KERNEL_BUILD_TIMEOUT_SECONDS:-10800}"
  [[ $deadline =~ ^[0-9]+$ && $deadline -gt 0 ]] || fail "KERNEL_BUILD_TIMEOUT_SECONDS must be a positive integer"

  local data_file job_file proxy_https proxy_http proxy_no
  build_temp_dir=$(mktemp -d)
  data_file="${build_temp_dir}/job-data.json"
  job_file="${build_temp_dir}/job.yaml"
  proxy_https="${HTTPS_PROXY:-${https_proxy:-}}"
  proxy_http="${HTTP_PROXY:-${http_proxy:-$proxy_https}}"
  proxy_no="${NO_PROXY:-${no_proxy:-}}"

  if [[ -n $proxy_https ]]; then
    jq -n \
      --arg job_name "$job_name" \
      --arg namespace "$namespace" \
      --arg builder_image "$builder_image" \
      --arg kernel_tree "$INPUT_KERNEL_TREE" \
      --arg kernel_ref "$INPUT_KERNEL_REF" \
      --arg architecture "$architecture" \
      --arg kernel_tag_overwrite "${INPUT_KERNEL_TAG_OVERWRITE:-}" \
      --argjson active_deadline_seconds "$deadline" \
      --arg http_proxy "$proxy_http" \
      --arg https_proxy "$proxy_https" \
      --arg no_proxy "$proxy_no" \
      '{job_name:$job_name,namespace:$namespace,builder_image:$builder_image,kernel_tree:$kernel_tree,kernel_ref:$kernel_ref,architecture:$architecture,kernel_tag_overwrite:$kernel_tag_overwrite,active_deadline_seconds:$active_deadline_seconds,proxy:{http_proxy:$http_proxy,https_proxy:$https_proxy,no_proxy:$no_proxy}}' \
      > "$data_file"
  else
    jq -n \
      --arg job_name "$job_name" \
      --arg namespace "$namespace" \
      --arg builder_image "$builder_image" \
      --arg kernel_tree "$INPUT_KERNEL_TREE" \
      --arg kernel_ref "$INPUT_KERNEL_REF" \
      --arg architecture "$architecture" \
      --arg kernel_tag_overwrite "${INPUT_KERNEL_TAG_OVERWRITE:-}" \
      --argjson active_deadline_seconds "$deadline" \
      '{job_name:$job_name,namespace:$namespace,builder_image:$builder_image,kernel_tree:$kernel_tree,kernel_ref:$kernel_ref,architecture:$architecture,kernel_tag_overwrite:$kernel_tag_overwrite,active_deadline_seconds:$active_deadline_seconds}' \
      > "$data_file"
  fi
  j2 "$template_dir/kernel-build-job.yaml.j2" "$data_file" -o "$job_file"
  kubectl create -f "$job_file"
  local job_uid
  job_uid=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.metadata.uid}')
  [[ -n $job_uid ]] || fail "could not read the created Job UID"
  kubectl create configmap "${job_name}-scripts" -n "$namespace" \
    --from-file="${template_dir}/kernel-build-job.sh" \
    --from-file="${template_dir}/build-kernel.sh" \
    --from-file="${template_dir}/get-base-kernel-artifacts.sh" \
    --from-file="${action_dir}/../kubevirt-action/registry.sh" \
    --dry-run=client -o json |
    jq --arg name "$job_name" --arg uid "$job_uid" \
      '.metadata.ownerReferences=[{apiVersion:"batch/v1",kind:"Job",name:$name,uid:$uid}]' |
    kubectl create -f -

  local KERNEL_BUILD_POD_NAME='' KERNEL_BUILD_POD_JSON=''
  local phase waiting_reason start_deadline job_deadline start_timeout poll_seconds
  local job_json current_uid succeeded failed termination_message kernel_version kernel_image_digest
  start_timeout="${KERNEL_BUILD_START_TIMEOUT_SECONDS:-900}"
  poll_seconds="${KERNEL_BUILD_POLL_SECONDS:-10}"
  [[ $start_timeout =~ ^[1-9][0-9]*$ ]] || fail "KERNEL_BUILD_START_TIMEOUT_SECONDS must be a positive integer"
  [[ $poll_seconds =~ ^[1-9][0-9]*$ ]] || fail "KERNEL_BUILD_POLL_SECONDS must be a positive integer"
  job_deadline=$((SECONDS + deadline + 600))
  start_deadline=$((SECONDS + start_timeout))
  while true; do
    verify_job_uid "$job_name" "$namespace" "$job_uid"
    lookup_job_pod "$job_name" "$namespace" "$job_uid"
    if [[ -n $KERNEL_BUILD_POD_NAME ]]; then
      phase=$(jq -r '.status.phase // "Pending"' <<< "$KERNEL_BUILD_POD_JSON") ||
        fail "could not read kernel build pod phase"
      waiting_reason=$(jq -r '[
        .status.containerStatuses[]?.state.waiting.reason // empty,
        (.status.conditions[]? | select(.status == "False") | .reason // empty)
      ] | map(select(length > 0)) | unique | join(",")' \
        <<< "$KERNEL_BUILD_POD_JSON") || fail "could not read kernel build pod waiting reason"
      printf 'kernel-build-job: pod=%s phase=%s waiting_reason=%s\n' \
        "$KERNEL_BUILD_POD_NAME" "$phase" "${waiting_reason:-none}"
      case "$phase" in
        Running|Succeeded) break ;;
        Failed)
          diagnostics "$job_name" "$namespace" "$KERNEL_BUILD_POD_NAME"
          fail "kernel build pod failed before starting"
          ;;
      esac
    else
      phase=Pending
      waiting_reason='pod has not been created'
      printf 'kernel-build-job: pod=none phase=%s waiting_reason=%s\n' \
        "$phase" "$waiting_reason"
    fi
    if (( SECONDS >= start_deadline )); then
      diagnostics "$job_name" "$namespace" "${KERNEL_BUILD_POD_NAME:-}"
      fail "timed out waiting for the kernel build pod to start"
    fi
    sleep "$poll_seconds"
  done

  kubectl logs -f "job/${job_name}" -n "$namespace" \
    --pod-running-timeout=5m || true
  while true; do
    job_json=$(kubectl get job "$job_name" -n "$namespace" -o json) ||
      fail "kernel build Job was replaced"
    current_uid=$(jq -r '.metadata.uid // empty' <<< "$job_json") ||
      fail "could not read kernel build Job UID"
    [[ $current_uid == "$job_uid" ]] || fail "kernel build Job was replaced"
    lookup_job_pod "$job_name" "$namespace" "$job_uid"
    succeeded=$(jq -r '.status.succeeded // 0' <<< "$job_json") ||
      fail "could not read kernel build Job status"
    failed=$(jq -r '.status.failed // 0' <<< "$job_json") ||
      fail "could not read kernel build Job status"
    if (( succeeded > 0 )); then
      break
    fi
    if (( failed > 0 )) || jq -e '.status.conditions[]? | select(.type == "Failed" and .status == "True")' <<< "$job_json" >/dev/null; then
      diagnostics "$job_name" "$namespace" "${KERNEL_BUILD_POD_NAME:-}"
      fail "kernel build Job failed"
    fi
    if (( SECONDS >= job_deadline )); then
      diagnostics "$job_name" "$namespace" "${KERNEL_BUILD_POD_NAME:-}"
      fail "timed out waiting for the kernel build Job"
    fi
    sleep "$poll_seconds"
  done

  verify_job_uid "$job_name" "$namespace" "$job_uid"
  lookup_job_pod "$job_name" "$namespace" "$job_uid"
  [[ -n $KERNEL_BUILD_POD_NAME ]] || fail "kernel build Job was replaced or its pod is missing"
  termination_message=$(jq -r '.status.containerStatuses[0].state.terminated.message // empty' \
    <<< "$KERNEL_BUILD_POD_JSON") || fail "could not read kernel build termination message"
  kernel_version=$(extract_result_value "$termination_message" KERNEL_VERSION) || kernel_version=''
  kernel_image_digest=$(extract_result_value "$termination_message" KERNEL_IMAGE_DIGEST) || kernel_image_digest=''
  if [[ -z $kernel_version || -z $kernel_image_digest ]]; then
    local fallback_logs fallback_version fallback_digest
    fallback_logs=$(kubectl logs "pod/${KERNEL_BUILD_POD_NAME}" \
      -n "$namespace" --tail=50) || fallback_logs=''
    fallback_version=$(extract_result_value "$fallback_logs" KERNEL_VERSION) || fallback_version=''
    fallback_digest=$(extract_result_value "$fallback_logs" KERNEL_IMAGE_DIGEST) || fallback_digest=''
    [[ -n $kernel_version ]] || kernel_version=$fallback_version
    [[ -n $kernel_image_digest ]] || kernel_image_digest=$fallback_digest
  fi
  [[ $kernel_version =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
    fail "Job returned invalid KERNEL_VERSION"
  [[ $kernel_image_digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "Job returned invalid KERNEL_IMAGE_DIGEST"

  printf 'kernel_version=%s\n' "$kernel_version" >> "$GITHUB_OUTPUT"
  printf 'kernel_image_digest=%s\n' "$kernel_image_digest" >> "$GITHUB_OUTPUT"
  printf 'Kernel image: container-registry.local:5000/linux-kernel-containerdisk@%s\n' \
    "$kernel_image_digest"
}

cleanup() {
  local job_name=${INPUT_JOB_NAME:-}
  [[ -n $job_name ]] || return 0
  local namespace
  namespace=$(get_build_namespace)
  kubectl delete job "$job_name" -n "$namespace" --ignore-not-found --wait=false || true
  kubectl delete configmap "${job_name}-scripts" -n "$namespace" \
    --ignore-not-found --wait=false || true
}

case "${1:-}" in
  build) build ;;
  cleanup) cleanup ;;
  *)
    printf 'usage: %s {build|cleanup}\n' "$0" >&2
    exit 2
    ;;
esac
