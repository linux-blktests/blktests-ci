#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

#TODO: use dind container that has kubectl and virtctl preinstalled
set -e
set -x
source vars.sh
sudo apt-get update
sudo apt-get -y install curl j2cli

# Install stable kubectl, query kubernetes server version and install compatible kubectl version
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo chmod +x kubectl
KUBE_SERVER_VERSION=$(./kubectl version -o json 2> /dev/null | jq -r '.serverVersion.gitVersion' | sed -E 's/^((v[0-9]+\.[0-9]+\.[0-9]+)).*/\1/')
curl -LO "https://dl.k8s.io/release/${KUBE_SERVER_VERSION}/bin/linux/amd64/kubectl"
sudo chmod +x kubectl

KUBEVIRT_VERSION=$(./kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}")
curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
sudo chmod +x virtctl

if [ ! -f ./identity ]; then
  ssh-keygen -b 2048 -t rsa -f ./identity -q -N ""
fi
export vm_ssh_authorized_keys=$(cat ./identity.pub | xargs)
export kernel_version=$INPUT_KERNEL_VERSION

j2 $(dirname "$0")/../../../playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/fedora-var-kernel-vm.yaml.j2 -o vm.yml
./kubectl create -f vm.yml
./kubectl wait vm ${vm_name} --for=jsonpath='{.status.printableStatus}'=Running --timeout=300s
#TODO: capture VM console in a log
#./virtctl console ${vm_name} | tee -a vm_console_output.log
while true; do
  echo "Waiting for VM to be up and running"
  ./virtctl ssh ${vm_user}@${vm_name} "${ssh_options[@]}" --command="ls /vm-ready" && break
  sleep 10
done

run_cmds=$INPUT_RUN_CMDS
./virtctl ssh ${vm_user}@${vm_name} "${ssh_options[@]}" --command="${run_cmds}"
