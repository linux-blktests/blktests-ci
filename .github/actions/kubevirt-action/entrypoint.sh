#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

function install_requirements() {
  sudo apt-get update
  sudo apt-get -y install curl j2cli unzip file

  # Install stable kubectl, query kubernetes server version and install compatible kubectl version
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo chmod +x kubectl
  KUBE_SERVER_VERSION=$(./kubectl version -o json 2> /dev/null | jq -r '.serverVersion.gitVersion' | sed -E 's/^((v[0-9]+\.[0-9]+\.[0-9]+)).*/\1/')
  curl -LO "https://dl.k8s.io/release/${KUBE_SERVER_VERSION}/bin/linux/amd64/kubectl"
  sudo chmod +x kubectl

  KUBEVIRT_VERSION=$(./kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}")
  curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
  sudo chmod +x virtctl

  curl -L -o logcli-linux-amd64.zip https://github.com/grafana/loki/releases/download/v3.6.2/logcli-linux-amd64.zip
  unzip -o logcli-linux-amd64.zip
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
  else
    # Auto-discover PCI host devices: query KubeVirt CR for permitted
    # pciHostDevices, then cross-reference with node allocatable resources
    permitted=$(./kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o json \
      | jq -c '[.spec.configuration.permittedHostDevices.pciHostDevices[].resourceName] | unique')
    devices_json=$(./kubectl get nodes -o json | jq -c --argjson permitted "$permitted" '
      [.items[].status.allocatable // {} | to_entries[]
        | select(.key as $k | $permitted | index($k))
        | select(.value != "0")]
      | unique_by(.key)
      | to_entries
      | map({
          name: (.value.key | ltrimstr("devices.kubevirt.io/") | . + "-0"),
          deviceName: .value.key
        })
    ')
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

  if [ -f /etc/ssl/certs/mitmproxy-ca-cert.pem ]; then
    export mitmproxy_ca_cert=$(cat /etc/ssl/certs/mitmproxy-ca-cert.pem)
  fi

  resolve_host_devices

  # Render cloud-init script and create a ConfigMap for the VM to consume via virtiofs
  j2 $(dirname "$0")/../../../playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/fedora-vm-init.sh.j2 -o init.sh
  ./kubectl create configmap ${vm_name}-cloud-init --from-file=init.sh=init.sh --dry-run=client -o yaml | ./kubectl apply -f -

  # Write YAML data file for VM template rendering (host_devices is a JSON
  # array which is valid YAML, so j2 parses it into a native list of dicts)
  cat > vm-data.yaml << EOF
vm_name: "${vm_name}"
kernel_version: "${kernel_version}"
vm_ssh_authorized_keys: "${vm_ssh_authorized_keys}"
host_devices: ${host_devices}
EOF

  # Render and create VM
  j2 $(dirname "$0")/../../../playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/fedora-var-kernel-vm.yaml.j2 vm-data.yaml -o vm.yml
  ./kubectl create -f vm.yml
  ./kubectl wait vm ${vm_name} --for=jsonpath='{.status.printableStatus}'=Running --timeout=300s
  while true; do
    echo "Waiting for VM to be up and running"
    ./virtctl ssh ${vm_user}@vmi/${vm_name} "${ssh_options[@]}" --command="ls /vm-ready" && break
    sleep 10
  done

  run_cmds="${INPUT_RUN_CMDS}"
  ./virtctl ssh ${vm_user}@vmi/${vm_name} "${ssh_options[@]}" --command="${run_cmds}"
}

function extract_test_artifacts_for_upload() {
  if [ -z "$1" ]; then
    echo "Error: The VM directory to upload must be specified."
    return 1
  fi
  vm_artifact_upload_dir="$1"
  rm -rf artifacts
  mkdir artifacts
  ./virtctl scp "${ssh_options[@]}" -r ${vm_user}@vmi/${vm_name}:/home/${vm_user}/${vm_artifact_upload_dir} artifacts
}

function extract_kernel_artifacts() {
  # We allow this step to fail, as we don't want to upload the kernel
  # artifacts multiple times in the same job.
  export kernel_version="${INPUT_KERNEL_VERSION}"
  dir="${HOME}/kernel-artifacts"
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
  ./kubectl describe vmi $vm_name > ./dmesg-logs/vmi-description.log
  log_pod_name=$(./kubectl get pods | grep -o "virt-launcher-${vm_name}-[^ ]*" | xargs)
  since_time=$(./kubectl get pods | grep "virt-launcher-${vm_name}-[^ ]*" | awk '{print $5}' | xargs)
  ./logcli-linux-amd64 --addr=http://loki.logging.svc.cluster.local:3100 query "{container=\"guest-console-log\", pod=\"${log_pod_name}\"}" --limit=0 --since=${since_time} > ./dmesg-logs/dmesg.log
}

function cleanup_vm() {
  ./kubectl delete -f vm.yml
  ./kubectl delete configmap ${vm_name}-cloud-init --ignore-not-found=true
}

#TODO: use dind container that has kubectl and virtctl preinstalled
set -euxo pipefail
source vars.sh

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
