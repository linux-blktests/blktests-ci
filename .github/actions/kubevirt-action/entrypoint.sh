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

function get_vm_namespace() {
  if [[ -n ${KUBEVIRT_VM_NAMESPACE:-} ]]; then
    printf '%s\n' "$KUBEVIRT_VM_NAMESPACE"
    return
  fi
  local namespace_file=/var/run/secrets/kubernetes.io/serviceaccount/namespace
  if [[ ! -r $namespace_file ]]; then
    echo "ERROR: cannot determine the VM namespace; $namespace_file is missing or unreadable." >&2
    return 1
  fi
  local namespace
  namespace=$(<"$namespace_file")
  if [[ -z $namespace ]]; then
    echo "ERROR: cannot determine the VM namespace; $namespace_file is empty." >&2
    return 1
  fi
  printf '%s-vm\n' "$namespace"
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
  if ! command -v j2 >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get -y install curl j2cli unzip jq
  fi
  ensure_kubectl
  ensure_virtctl
  ensure_logcli
}

function install_build_requirements() {
  if ! command -v j2 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get -y install j2cli jq
  fi
  ensure_kubectl
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

# Print concise scheduling/boot diagnostics for the current VM to the step log.
# Called when the VM never becomes ready so the reason (Unschedulable, image
# pull error, boot hang, ...) is visible inline; the full guest serial console
# is still collected separately by the always() extract_dmesg_logs step.
function dump_vm_diagnostics() {
  echo "===== diagnostics for ${vm_name} ====="
  kubectl describe vm "${vm_name}" -n "$vm_namespace" || true
  kubectl describe vmi "${vm_name}" -n "$vm_namespace" || true
  local vmi_uid pod
  vmi_uid=$(kubectl get vmi "${vm_name}" -n "$vm_namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  if [ -n "${vmi_uid}" ]; then
    pod=$(kubectl get pods -l kubevirt.io/created-by="${vmi_uid}" -n "$vm_namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${pod}" ]; then
      kubectl describe pod "${pod}" -n "$vm_namespace" || true
    fi
  fi
}

function run_ssh_cmds() {
  if [ ! -f ./identity ]; then
    ssh-keygen -b 2048 -t rsa -f ./identity -q -N ""
  fi
  export vm_ssh_authorized_keys=$(cat ./identity.pub | xargs)
  export kernel_version="${INPUT_KERNEL_VERSION}"
  export kernel_image_digest="${INPUT_KERNEL_IMAGE_DIGEST:-}"

  if [[ -n $kernel_image_digest ]]; then
    [[ -n $kernel_version ]] || {
      echo "ERROR: kernel_image_digest requires kernel_version." >&2
      return 1
    }
    [[ $kernel_image_digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "ERROR: invalid kernel_image_digest '${kernel_image_digest}'." >&2
      return 1
    }
  fi

  if [ "${guest_os}" = "freebsd" ] && [ -n "${kernel_version}" ]; then
    echo "ERROR: kernel_version is not supported for FreeBSD guests (custom kernels are Linux-only); got '${kernel_version}'." >&2
    return 1
  fi

  mitmproxy_ca_cert_path="${MITMPROXY_CA_CERT_PATH:-/etc/ssl/certs/mitmproxy-ca-cert.pem}"
  if [ -f "$mitmproxy_ca_cert_path" ]; then
    export mitmproxy_ca_cert=$(cat "$mitmproxy_ca_cert_path")
  fi

  resolve_host_devices

  # Render the init script and create a ConfigMap for the VM to consume. j2
  # with no data file renders from the exported environment (e.g. distro,
  # vm_user, kernel_version, mitmproxy_ca_cert). Linux guests mount the
  # ConfigMap via virtiofs.
  if [ "${guest_os}" = "freebsd" ]; then
    j2 ${TEMPLATES_DIR}/vm-init-freebsd.sh.j2 -o init.sh
    # FreeBSD has no virtio-fs, so the ConfigMap becomes the NoCloud "cidata"
    # disk (see vm.yaml.j2) and has to carry user-data and meta-data. nuageinit
    # unmounts that disk before runcmd runs, so write_files copies the script
    # out while it is still mounted. bootcmd would be the natural fit, but the
    # nuageinit in FreeBSD 15.1 silently ignores it.
    script_b64="$(base64 -w0 init.sh)"
    cat > user-data << EOF
#cloud-config
users:
  - name: ${vm_user}
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/sh
    ssh_authorized_keys:
      - ${vm_ssh_authorized_keys}
write_files:
  - path: /root/init.sh
    permissions: "0755"
    encoding: base64
    content: ${script_b64}
runcmd:
  - "/bin/sh /root/init.sh"
EOF
    printf 'instance-id: %s\nlocal-hostname: %s\n' "${vm_name}" "${vm_name}" > meta-data
    kubectl create configmap ${vm_name}-cloud-init -n "$vm_namespace" \
      --from-file=user-data=user-data \
      --from-file=meta-data=meta-data \
      --dry-run=client -o yaml | kubectl apply -n "$vm_namespace" -f -
  else
    j2 ${TEMPLATES_DIR}/vm-init.sh.j2 -o init.sh
    kubectl create configmap ${vm_name}-cloud-init -n "$vm_namespace" --from-file=init.sh=init.sh --dry-run=client -o yaml | kubectl apply -n "$vm_namespace" -f -
  fi

  # Write YAML data file for VM template rendering (host_devices is a JSON
  # array which is valid YAML, so j2 parses it into a native list of dicts)
  cat > vm-data.yaml << EOF
vm_name: "${vm_name}"
architecture: "${architecture}"
kernel_version: "${kernel_version}"
kernel_image_digest: "${kernel_image_digest}"
vm_ssh_authorized_keys: "${vm_ssh_authorized_keys}"
host_devices: ${host_devices}
container_disk_image: "${container_disk_image}"
distro: "${distro}"
vm_user: "${vm_user}"
root_device: "${root_device}"
root_flags: "${root_flags}"
guest_os: "${guest_os}"
EOF

  # Render and create VM
  j2 ${TEMPLATES_DIR}/vm.yaml.j2 vm-data.yaml -o vm.yml
  kubectl create -n "$vm_namespace" -f vm.yml
  # EFI/OVMF boot plus enumeration of a passed-through HBA option ROM makes
  # host-device VMs noticeably slower to reach "Running"; the previous 300s was
  # too tight and produced intermittent "timed out waiting for Running"
  # failures. Give them more headroom (overridable via VM_RUNNING_TIMEOUT).
  local running_timeout="${VM_RUNNING_TIMEOUT:-600}"
  if ! kubectl wait vm ${vm_name} -n "$vm_namespace" --for=jsonpath='{.status.printableStatus}'=Running --timeout="${running_timeout}s"; then
    echo "ERROR: ${vm_name} did not reach Running within ${running_timeout}s." >&2
    dump_vm_diagnostics || true
    return 1
  fi
  # Wait for the guest to finish provisioning. cloud-init/init.sh touches
  # /vm-ready on success (or /vm-init-failed on error). This loop used to be
  # unbounded, so a VM that never became reachable (firmware/boot hang) or whose
  # init stalled would spin here until the 1200-minute job timeout -- i.e. hang
  # for ~20h. Bound it with a deadline instead: on timeout (or an init failure)
  # dump diagnostics and fail the step, so the always() cleanup/log-collection
  # steps run and the job ends promptly. Tune with VM_READY_TIMEOUT (seconds).
  local ready_timeout="${VM_READY_TIMEOUT:-1200}"
  local ready_deadline=$(( SECONDS + ready_timeout ))
  while true; do
    local rc=0
    virtctl ssh -n "$vm_namespace" ${vm_user}@vmi/${vm_name} "${ssh_options[@]}" \
      --command='test -f /vm-ready && exit 0; test -f /vm-init-failed && exit 3; exit 2' || rc=$?
    [ "${rc}" -eq 0 ] && break
    if [ "${rc}" -eq 3 ]; then
      echo "ERROR: guest provisioning failed; /vm-init-failed present in ${vm_name}:" >&2
      virtctl ssh -n "$vm_namespace" ${vm_user}@vmi/${vm_name} "${ssh_options[@]}" --command='cat /vm-init-failed' || true
      dump_vm_diagnostics || true
      return 1
    fi
    if [ "${SECONDS}" -ge "${ready_deadline}" ]; then
      echo "ERROR: ${vm_name} not ready within ${ready_timeout}s (guest unreachable or init stuck)." >&2
      dump_vm_diagnostics || true
      return 1
    fi
    echo "Waiting for VM to be up and running (timeout in $(( ready_deadline - SECONDS ))s)"
    sleep 10
  done

  run_cmds="${INPUT_RUN_CMDS}"
  # Linux guests export the test devices and the proxy via /etc/environment
  # (pam_env). FreeBSD has no equivalent, so source the file the guest wrote
  # them to.
  # NOTE: blktests is not designed for execution on FreeBSD. The purpose of
  # this feature is to test integration with applications such as nvme-cli.
  if [ "${guest_os}" = "freebsd" ]; then
    run_cmds="set -a; . /etc/ci-devices.env; set +a
${run_cmds}"
  fi
  virtctl ssh -n "$vm_namespace" ${vm_user}@vmi/${vm_name} "${ssh_options[@]}" --command="${run_cmds}"
}

function extract_test_artifacts_for_upload() {
  if [ -z "$1" ]; then
    echo "Error: The VM directory to upload must be specified."
    return 1
  fi
  vm_artifact_upload_dir="$1"
  rm -rf artifacts
  mkdir artifacts
  virtctl scp -n "$vm_namespace" "${ssh_options[@]}" -r ${vm_user}@vmi/${vm_name}:/home/${vm_user}/${vm_artifact_upload_dir} artifacts
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

  registry_extract \
    "${KERNEL_IMAGE_REGISTRY_URL:-http://registry-service.docker-registry.svc.cluster.local}" \
    linux-kernel-containerdisk \
    "${INPUT_KERNEL_IMAGE_DIGEST:-$kernel_version}" \
    "$dir" boot
}

function extract_dmesg_logs() {
  rm -rf dmesg-logs
  mkdir dmesg-logs
  kubectl describe vmi $vm_name -n "$vm_namespace" > ./dmesg-logs/vmi-description.log
  vmi_uid=$(kubectl get vmi "${vm_name}" -n "$vm_namespace" -o jsonpath='{.metadata.uid}')
  log_pod_name=$(kubectl get pods -l kubevirt.io/created-by="${vmi_uid}" -n "$vm_namespace" -o jsonpath='{.items[0].metadata.name}')
  since_time=$(kubectl get pods -l kubevirt.io/created-by="${vmi_uid}" -n "$vm_namespace" --no-headers | awk 'NR==1{print $5}' | xargs)
  logcli --addr=http://loki.logging.svc.cluster.local:3100 query "{container=\"guest-console-log\", pod=\"${log_pod_name}\"}" --limit=0 --since=${since_time} > ./dmesg-logs/dmesg.log
}

function cleanup_vm() {
  kubectl delete -f vm.yml -n "$vm_namespace"
  kubectl delete configmap ${vm_name}-cloud-init -n "$vm_namespace" --ignore-not-found=true
}

set -euxo pipefail
source "$(dirname "$0")/vars.sh"
source "$(dirname "$0")/registry.sh"

# Directory holding the KubeVirt VM Jinja2 templates. Defaults to the in-repo
# path used by the GitHub composite action; the kubevirt runner image consumed
# by GitLab CI overrides it via the TEMPLATES_DIR environment variable.
TEMPLATES_DIR="${TEMPLATES_DIR:-$(dirname "$0")/../../../playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates}"

case "$1" in
  install_requirements)
    vm_namespace="$(get_vm_namespace)"
    install_requirements
    ;;
  install_build_requirements)
    vm_namespace="$(get_vm_namespace)"
    install_build_requirements
    ;;
  run_ssh_cmds)
    vm_namespace="$(get_vm_namespace)"
    run_ssh_cmds
    ;;
  extract_test_artifacts_for_upload)
    vm_namespace="$(get_vm_namespace)"
    extract_test_artifacts_for_upload "$2"
    ;;
  extract_kernel_artifacts)
    vm_namespace="$(get_vm_namespace)"
    extract_kernel_artifacts
    ;;
  extract_dmesg_logs)
    vm_namespace="$(get_vm_namespace)"
    extract_dmesg_logs
    ;;
  cleanup_vm)
    vm_namespace="$(get_vm_namespace)"
    cleanup_vm
    ;;
  *)
    echo "Unknown action $1"
    exit 1
    ;;
esac
