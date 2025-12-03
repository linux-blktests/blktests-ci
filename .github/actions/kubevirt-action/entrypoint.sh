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
  curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
  sudo chmod +x virtctl

  curl -L -o logcli-linux-amd64.zip https://github.com/grafana/loki/releases/download/v3.6.2/logcli-linux-amd64.zip
  unzip -o logcli-linux-amd64.zip
}

function run_ssh_cmds() {
  if [ ! -f ./identity ]; then
    ssh-keygen -b 2048 -t rsa -f ./identity -q -N ""
  fi
  export vm_ssh_authorized_keys=$(cat ./identity.pub | xargs)
  export kernel_version=$INPUT_KERNEL_VERSION

  j2 $(dirname "$0")/../../../playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/fedora-var-kernel-vm.yaml.j2 -o vm.yml
  ./kubectl create -f vm.yml
  ./kubectl wait vm ${vm_name} --for=jsonpath='{.status.printableStatus}'=Running --timeout=300s
  while true; do
    echo "Waiting for VM to be up and running"
    ./virtctl ssh ${vm_user}@${vm_name} "${ssh_options[@]}" --command="ls /vm-ready" && break
    sleep 10
  done

  run_cmds=$INPUT_RUN_CMDS
  ./virtctl ssh ${vm_user}@${vm_name} "${ssh_options[@]}" --command="${run_cmds}"
}

function extract_test_artifacts_for_upload() {
  if [ -z "$1" ]; then
    echo "Error: The VM directory to upload must be specified."
    return 1
  fi
  vm_artifact_upload_dir=$1
  rm -rf artifacts
  mkdir artifacts
  ./virtctl scp "${ssh_options[@]}" -r ${vm_user}@${vm_name}:/home/${vm_user}/${vm_artifact_upload_dir} artifacts
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
    if file "$f" | grep -q "POSIX tar archive"; then
      tar -xf "$f" -C $dir
    fi
  done
  cd ~
}

function extract_dmesg_logs() {
  rm -rf dmesg-logs
  mkdir dmesg-logs
  ./kubectl describe vmi $vm_name > ./dmesg-logs/vmi-description.log
  log_pod_name=$(./kubectl describe vmi $vm_name | grep -o "virt-launcher-${vm_name}-[^ ]*" | xargs)
  since_time=$(./kubectl describe vmi $vm_name | grep "virt-launcher-${vm_name}-[^ ]*" | awk '{print $3}' | xargs)
  ./logcli-linux-amd64 --addr=http://loki.logging.svc.cluster.local:3100 query "{container=\"guest-console-log\", pod=\"${log_pod_name}\"}" --limit=0 --since=${since_time} > ./dmesg-logs/dmesg.log
}

function cleanup_vm() {
  ./kubectl delete -f vm.yml
}

#TODO: use dind container that has kubectl and virtctl preinstalled
set -e
set -x
source vars.sh

case $1 in
  install_requirements)
    install_requirements
    ;;
  run_ssh_cmds)
    run_ssh_cmds
    ;;
  extract_test_artifacts_for_upload)
    extract_test_artifacts_for_upload $2
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
