#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

# Normalize a Kubernetes-style version string to vMAJOR.MINOR.PATCH.
function _norm_ver() {
  echo "$1" | sed -E 's/^(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

# Download <url> and install it onto PATH as /usr/local/bin/<name> (executable).
function _install_bin() {
  curl -fsSL -o "/tmp/$2" "$1"
  sudo install -m 0755 "/tmp/$2" "/usr/local/bin/$2"
  rm -f "/tmp/$2"
}

# In-cluster HTTP cache (deployed by the k8s-install-ci-binary-cache role) that
# serves version-matched kubectl/virtctl/logcli. The default resolves over
# cluster DNS and is covered by the runner pods' NO_PROXY, so it bypasses any
# mitmproxy.
CI_TOOLS_CACHE_URL="http://ci-bin-cache.ci-tools.svc.cluster.local"

# Install <name> from the in-cluster cache onto PATH. Returns non-zero without
# touching the system when the cache is unreachable or has not populated
function _install_from_cache() {
  local name="$1"
  curl -fsSL -o "/tmp/${name}" "${CI_TOOLS_CACHE_URL}/${name}" || return 1
  sudo install -m 0755 "/tmp/${name}" "/usr/local/bin/${name}" || { rm -f "/tmp/${name}"; return 1; }
  rm -f "/tmp/${name}"
}

# kubectl: served from the cache pre-matched to the live server version. The
# fallback bootstraps from the stable release and then installs the
# server-matched build.
function ensure_kubectl() {
  command -v kubectl >/dev/null 2>&1 && return 0
  _install_from_cache kubectl && return 0
  echo "WARNING: CI binary cache unavailable; downloading kubectl from the internet." >&2
  _install_bin "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" kubectl
  local server
  server="$(_norm_ver "$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')")"
  [ -n "$server" ] && _install_bin "https://dl.k8s.io/release/${server}/bin/linux/amd64/kubectl" kubectl
}

# virtctl: served from the cache pre-matched to the observed KubeVirt version.
# The fallback queries the cluster and downloads the matching GitHub release.
function ensure_virtctl() {
  command -v virtctl >/dev/null 2>&1 && return 0
  _install_from_cache virtctl && return 0
  echo "WARNING: CI binary cache unavailable; downloading virtctl from the internet." >&2
  local cluster
  cluster="$(kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath='{.status.observedKubeVirtVersion}' 2>/dev/null || true)"
  [ -n "$cluster" ] && _install_bin "https://github.com/kubevirt/kubevirt/releases/download/${cluster}/virtctl-${cluster}-linux-amd64" virtctl
}

# logcli is pinned (no cluster dependency). Prefer the cache, fall back to the
# pinned GitHub release.
function ensure_logcli() {
  command -v logcli >/dev/null 2>&1 && return 0
  _install_from_cache logcli && return 0
  echo "WARNING: CI binary cache unavailable; downloading logcli from the internet." >&2
  curl -fsSL -o /tmp/logcli.zip "https://github.com/grafana/loki/releases/download/${LOGCLI_VERSION:-v3.6.2}/logcli-linux-amd64.zip"
  unzip -o /tmp/logcli.zip -d /tmp
  sudo install -m 0755 /tmp/logcli-linux-amd64 /usr/local/bin/logcli
  rm -f /tmp/logcli.zip /tmp/logcli-linux-amd64
}

function install_requirements() {
  # Base tooling is baked into the kubevirt runner image; only install it when
  # missing (e.g. on the GitHub actions-runner image).
  if ! command -v j2 >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || ! command -v file >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get -y install curl j2cli unzip file
  fi
  ensure_kubectl
  ensure_virtctl
  ensure_logcli
}

function resolve_host_devices() {
  local devices_json="[]"

  if [ -n "${INPUT_HOST_DEVICES:-}" ]; then
    # Parse comma-separated short device names into a JSON array
    # Duplicates are supported to request multiple devices of the same type
    declare -A device_counters
    devices_json="["
    local first=true
    IFS=',' read -ra DEVICES <<< "${INPUT_HOST_DEVICES}"
    for dev in "${DEVICES[@]}"; do
      dev=$(echo "$dev" | xargs) # trim whitespace
      [ -z "$dev" ] && continue
      local count=${device_counters[$dev]:-0}
      device_counters[$dev]=$((count + 1))
      local name="${dev}-${count}"
      if [ "$first" = true ]; then
        first=false
      else
        devices_json+=","
      fi
      devices_json+="{\"name\":\"${name}\",\"deviceName\":\"devices.kubevirt.io/${dev}\"}"
    done
    devices_json+="]"
  fi

  export host_devices="${devices_json}"
  echo "Resolved host devices: ${host_devices}"
}

function run_ssh_cmds() {
  if [ ! -f ./identity ]; then
    ssh-keygen -b 2048 -t rsa -f ./identity -q -N ""
  fi
  export vm_ssh_authorized_keys=$(cat ./identity.pub | xargs)
  export kernel_version="${INPUT_KERNEL_VERSION}"

  mitmproxy_ca_cert_path="${MITMPROXY_CA_CERT_PATH:-/etc/ssl/certs/mitmproxy-ca-cert.pem}"
  if [ -f "$mitmproxy_ca_cert_path" ]; then
    export mitmproxy_ca_cert=$(cat "$mitmproxy_ca_cert_path")
  fi

  resolve_host_devices

  # Render cloud-init script and create a ConfigMap for the VM to consume via virtiofs
  j2 ${TEMPLATES_DIR}/fedora-vm-init.sh.j2 -o init.sh
  kubectl create configmap ${vm_name}-cloud-init --from-file=init.sh=init.sh --dry-run=client -o yaml | kubectl apply -f -

  # Write YAML data file for VM template rendering (host_devices is a JSON
  # array which is valid YAML, so j2 parses it into a native list of dicts)
  cat > vm-data.yaml << EOF
vm_name: "${vm_name}"
kernel_version: "${kernel_version}"
vm_ssh_authorized_keys: "${vm_ssh_authorized_keys}"
host_devices: ${host_devices}
container_disk_image: "${container_disk_image}"
EOF

  # Render and create VM
  j2 ${TEMPLATES_DIR}/fedora-var-kernel-vm.yaml.j2 vm-data.yaml -o vm.yml
  kubectl create -f vm.yml
  kubectl wait vm ${vm_name} --for=jsonpath='{.status.printableStatus}'=Running --timeout=300s
  while true; do
    echo "Waiting for VM to be up and running"
    virtctl ssh ${vm_user}@vmi/${vm_name} "${ssh_options[@]}" --command="ls /vm-ready" && break
    sleep 10
  done

  run_cmds="${INPUT_RUN_CMDS}"
  virtctl ssh ${vm_user}@vmi/${vm_name} "${ssh_options[@]}" --command="${run_cmds}"
}

function extract_test_artifacts_for_upload() {
  if [ -z "$1" ]; then
    echo "Error: The VM directory to upload must be specified."
    return 1
  fi
  vm_artifact_upload_dir="$1"
  rm -rf artifacts
  mkdir artifacts
  virtctl scp "${ssh_options[@]}" -r ${vm_user}@vmi/${vm_name}:/home/${vm_user}/${vm_artifact_upload_dir} artifacts
}

function extract_kernel_artifacts() {
  # We allow this step to fail, as we don't want to upload the kernel
  # artifacts multiple times in the same job.
  # Nothing to extract when the VM booted its default kernel (no kernel_version
  # supplied); exit non-zero to skip the artifact upload, like the dedup case.
  if [ -z "${INPUT_KERNEL_VERSION:-}" ]; then
    echo "No kernel_version supplied; skipping kernel artifact extraction."
    exit 1
  fi
  export kernel_version="${INPUT_KERNEL_VERSION}"
  dir="${KERNEL_ARTIFACTS_DIR:-${HOME}/kernel-artifacts}"
  if [[ -d "$dir" ]]; then
    if ls ${dir}/boot | grep ${kernel_version}; then
      echo "Kernel artifacts already extracted. Skipping..."
      exit 1
    fi
  else
    mkdir $dir
  fi

  mkdir -p tmp
  cd tmp
  # Extracting the /boot directory from the container disk.
  # This containerdisk only contains this directory, so the image can't
  # be run as a container for extracting the kernel artifacts.
  docker pull registry-service.docker-registry.svc.cluster.local/linux-kernel-containerdisk:${kernel_version}
  docker save registry-service.docker-registry.svc.cluster.local/linux-kernel-containerdisk:${kernel_version} > tmp-containerdisk.tar
  tar -xf tmp-containerdisk.tar
  cd blobs/sha256
  for f in *; do
    if file -z "$f" | grep -q "POSIX tar archive"; then
      tar -xf "$f" -C $dir
    fi
  done
  cd ~
}

function extract_dmesg_logs() {
  rm -rf dmesg-logs
  mkdir dmesg-logs
  kubectl describe vmi $vm_name > ./dmesg-logs/vmi-description.log
  vmi_uid=$(kubectl get vmi "${vm_name}" -o jsonpath='{.metadata.uid}')
  log_pod_name=$(kubectl get pods -l kubevirt.io/created-by="${vmi_uid}" -o jsonpath='{.items[0].metadata.name}')
  since_time=$(kubectl get pods -l kubevirt.io/created-by="${vmi_uid}" --no-headers | awk 'NR==1{print $5}' | xargs)
  logcli --addr=http://loki.logging.svc.cluster.local:3100 query "{container=\"guest-console-log\", pod=\"${log_pod_name}\"}" --limit=0 --since=${since_time} > ./dmesg-logs/dmesg.log
}

function cleanup_vm() {
  kubectl delete -f vm.yml
  kubectl delete configmap ${vm_name}-cloud-init --ignore-not-found=true
}

set -euxo pipefail
source "$(dirname "$0")/vars.sh"

# Directory holding the KubeVirt VM Jinja2 templates. Defaults to the in-repo
# path used by the GitHub composite action; the kubevirt runner image consumed
# by GitLab CI overrides it via the TEMPLATES_DIR environment variable.
TEMPLATES_DIR="${TEMPLATES_DIR:-$(dirname "$0")/../../../playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates}"

case "$1" in
  install_requirements)
    install_requirements
    ;;
  run_ssh_cmds)
    run_ssh_cmds
    ;;
  extract_test_artifacts_for_upload)
    extract_test_artifacts_for_upload "$2"
    ;;
  extract_kernel_artifacts)
    extract_kernel_artifacts
    ;;
  extract_dmesg_logs)
    extract_dmesg_logs
    ;;
  cleanup_vm)
    cleanup_vm
    ;;
  *)
    echo "Unknown action $1"
    exit 1
    ;;
esac
