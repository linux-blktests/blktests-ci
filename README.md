# blktests-ci
This is a collection of Ansible scripts to help bootstrap a k8s cloud
environment with the focus on making PCIe devices available for testing.

This project adds automated infrastructure for Continuous Integration (CI) to
blktests and other projects, allowing to automatically execute the test suite
when new storage related kernel contributions are proposed.

### 📝TODOs
- kernel-builder-scale set is limited to 4 cpus and 8Gi memory
  -> this should be configurable
- move vm-template in this repo and make the resource consumption variable

## Architecture
To achieve maximal flexibility and good resource utilization we decided to
build a Kubernetes infrastructure that is capable of running multiple different
kernel test workloads on the same set of hardware resources.

The requirements for kernel testing are that we want to build and test a kernel
on demand triggered by a single GitHub workflow.
This workflow defines the exact kernel, test and on which physical devices
the tests should be run on.

We can't use a pre-registered self-hosted GitHub runner instance to simply
pick up a workflow and install/reboot a new kernel because it would lose
connection and fail the workflow. Nested VMs would be a possible solution,
however, it lacks the good resource utilization.

This figure illustrates the architecture:

![arch](./doc/blktests-ci-architecture.png?raw=true)

## Getting started
---

#### ⚠️ Warning
These scripts are by no means production ready. Please continue with caution
and expect the worst!

The setup was tested in a 3 node Dell-R6525 ubuntu-22.04 (deployed via MaaS)
cluster connected via NVIDIA® Mellanox® ConnectX®-6 Dx SmartNICs and populated
with multiple different NVMe™ SSDs used for testing.
Each node has a 2 TB boot drive that is also used for non-critical cluster
storage.

A Linux distribution is required to be installed on each of the nodes to
continue with this guide.

---

### Install dependencies
The following tools need to be installed on the machine you want to orchestrate
your cluster from. This machine will be referred to as 'workstation' from now
on.

- Python
- Ansible
- Docker (or Podman in combination with podman-docker)
- kubectl
- helm
- virtctl (version must match with definition in `variables.yaml`)

The workstation needs network access to the cluster nodes.

### Prepare setup on workstation 
Next please review the entries in the `variables.yaml` and run
`ansible-vault create secrets.enc` to set the secret variables mentioned at the
end of the variables file.

The `secrets.enc` file should not be committed and can be edited via
`ansible-vault edit secrets.enc`. Simply rerunning the scripts might not be
sufficient to change the secret values.

Now copy `k8s-inventory-template.yaml` to `k8s-inventory.yaml` and adjust the
node-ips.

The bare metal OS installation on the cluster nodes is out of scope of this
project. One could use Proxmox or similar software.

Now is a great time to check on the cluster nodes that the
NVIDIA® Mellanox® ConnectX®-6 Dx SmartNIC and all PCIe devices that shall be
passed to KubeVirt VMs (for CI testing) are rebound to the vfio driver on
every startup (e.g. through kernel arguments).

---

#### 📝TODO

- Improve scripts by making any SmartNIC a configurable `variables.yaml` entry
  instead of hard coding in
  `playbook/roles/configure-physical-k8s-cluster-node/tasks/enp129s0f0np0.rules`
  and
  `playbook/install-k8s-requirements.yaml`
  (sriov and multus config)

---

Next make sure to adjust the `kubevirt-config.yaml` to define the same PCIe
devices from last step (besides the SmartNIC) in `pciHostDevices`:
`playbook/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml`

---

#### 📝TODO

- Make the `pciHostDevices` KubeVirt configuration pluggable in the
  variables.yaml instead of hard coding in
  `playbook/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml`

---

### Installing Kubernetes on the nodes
Next we are [deploying a k3s cluster](https://docs.k3s.io/quick-start) on our
nodes.

On the first node run:
```
#https://docs.k3s.io/datastore/ha-embedded
ufw disable
curl -sfL https://get.k3s.io | sh -s - server --nonroot-devices --cluster-init
cat /var/lib/rancher/k3s/server/node-token
```

On all other nodes run:
```
ufw disable
# K3S_TOKEN can be found on the first node at /var/lib/rancher/k3s/server/node-token
curl -sfL https://get.k3s.io | K3S_TOKEN=<secret from first node> sh -s - server --nonroot-devices --server https://<ip or hostname of first node>:6443
```

Because we deploy longhorn on the bare metal cluster later, we need to use the
`--nonroot-devices` flag when installing k3s. This sets the
`device_ownership_from_security_context` in containerd
(see https://github.com/k3s-io/k3s/issues/11168).

---

#### 📝TODO

- Create Ansible script for deploying k3s on the cluster nodes

---

### Establishing a connection from k3s to your workstation
Copy `/etc/rancher/k3s/k3s.yaml` from one of the cluster nodes to
`~/.kube/config` on your workstation and change `127.0.0.1` to the
cluster node IP.

Verify the connection with `kubectl get nodes`.

### Installing Kubernetes requirements for the CI infra
Now we can install all Kubernetes requirements for the CI infrastructure
that are provided by this project. To do so, run the following command on your
workstation in the root of this repository:

```
ansible-playbook -i k8s-inventory.yaml playbooks/install-k8s-requirements.yaml --ask-vault-pass
```

### Allowing insecure access to the self-hosted container registry

We are self-hosting a container registry on the k8s cluster for kernel builds
and other artifacts. The cluster was already configured by the previous step to
accept this registry.
We now have to configure the workstation to also be able to push and pull from
this registry.
On your workstation edit `/etc/docker/daemon.json` to contain:

```
{
  "insecure-registries": ["<k8s-node-ip>:32000"]
}
```

Now test the connection with
```
docker pull nginx:latest
docker tag nginx:latest <k8s-node-ip>:32000/nginx:latest
docker push <k8s-node-ip>:32000/nginx:latest
```

---

#### 📝TODO

- Create Ansible script for adding this self-hosted repository to the
  workstation in a non-destructive way

---

## Creating new GitHub runner scale sets

The second main contribution of this project is to be able to spawn GitHub
runner scale sets according to the [proposed architecture](##Architecture)
for different GitHub projects.

We need to generate a new fine-grained personal access token for the repository
or organization, to allow the runner to pick up and process GitHub actions.

Follow the steps from [here](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token)
and make the following least privilege choices:

```
For point 7   (Expiration) please select "No expiration" or the longest period
              possible.
For point 9   (Owner resource) plese select the corresponding owning entity of
              the Repository that should subscirbe to the runner sets
For point 11  (Repository access) please select "Only select repositories" and
              add ONLY the one repository that reqires the self-hosted testing
              infrastructure.
For point 13  (Permissions) please select the following options for Repository
              permissions (the rest should be granted "No access"):
  Actions:        Read and write
  Administration: Read and write
  Contents:       Read-only
  Environments:   Read-only
  Merge queues:   Read-only
  Metadata:       Read-only
  Pull request:   Read-only
  Secrets:        Read-only
  Variables:      Read and write
  Webhooks:       Read and write
  Worflow:        Read and write
```

Please always share the token only on a secure channel!

With this token please extract the workflow_id of the workflow in question as
described on [this page](https://docs.github.com/en/rest/actions/workflows?apiVersion=2022-11-28#list-repository-workflows).


Finally, run the following command in the root of this repository and answer the
prompts to create the runner scale sets:
```
ansible-playbook -i k8s-inventory.yaml playbooks/setup-github-runner-scale-set.yaml
```

The two runner scale sets `arc-kernel-builder` and `arc-vm-runner-set` should now
be visible in the Repo->Settings->Actions->Runners overview.

### Debug help
ARC listeners can be inspected via `kubectl get pods -n arc-systems`.
ARC related pods can be inspected via `kubectl get pods -n gh-runner-<repo-name>`.
VMs can be inspected via `kubectl get vmi --all-namespaces`.
VM templates can be inspected via `kubectl get vmi --all-namespaces`.

### Deleting a runner scale set

```
helm delete arc-vm-runner-set -n gh-runner-<repo-name>
helm delete arc-kernel-builder -n gh-runner-<repo-name>
kubectl delete vm vm-template -n gh-runner-<repo-name>
kubectl delete secret github-config-secret -n gh-runner-<repo-name>
#Double check that everything is deleted:
kubectl get all -n gh-runner-<repo-name>
kubectl delete ns gh-runner-<repo-name>
```

---

#### 📝TODO

- Create Ansible script for deleting a runner scale set

---

## Further notes and tips
### Using private docker registry
On your workstation:
```
docker pull nginx:latest
docker tag nginx:latest <k8s-node-ip>:32000/nginx:latest
docker push <k8s-node-ip>:32000/nginx:latest
```
In the k8s deployments the container image can be specified by (This is a
mirror name on the k3s config):
`container-registry.local:5000/nginx:latest`

In docker-in-docker (dind) deployments refer to the registry like so:
`registry-service.docker-registry.svc.cluster.local`

E.g.:
daemon.json:
```
{
  "insecure-registries" : ["registry-service.docker-registry.svc.cluster.local"]
}
```

```
kubectl create configmap daemon-config --from-file=daemon.json
```

```
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Pod
metadata:
  name: docker
  labels:
    app: docker
spec:
  containers:
  - image: docker:24.0.0-rc.1-dind
    imagePullPolicy: IfNotPresent
    name: docker
    securityContext:
      privileged: true
    volumeMounts:
    - name: daemon-config
      mountPath: /etc/docker/daemon.json
      subPath: daemon.json
  restartPolicy: Always
  volumes:
  - name: daemon-config
    configMap:
      name: daemon-config
EOF
```

### Downloading a VM's image:
You might need to issue this command multiple times until the vmexport timeout
is not canceling this command. The image should be in the raw format to be
consumed by qemu. It can be in compressed format to reuse the image with
kubevirt (see virtctl manual).

```
#via shutoff vm
virtctl vmexport download vmexportname --vm <vm-name> --format raw --output=/path/to/vm-export.raw --port-forward
#or via snapshot:
virtctl vmexport download vmexportname --snapshot <vm-snapshot-name> --format raw --output=/path/to/vm-export.raw --port-forward
```

### Adding new PCIe devices to consume in KubeVirt VMs
Adjust and commit the
`playbooks/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml` file of
this repository to add another `pciHostDevices` entry. Use `lspci -n` to get
the vendor and device ID of the PCIe device that should be consumed by
KubeVirt VMs.

Rebind the driver of the PCIe device in question to the vfio driver and adjust
the options `vfio_pci.ids=VENDOR_ID0:DEVICE_ID0,VENDOR_ID1:DEVICE_ID1` to
contain the new vendor and device ID.

After adjusting and committing the `kubevirt-config.yaml` file, apply(=update) it
to the bare metal cluster from one of the control nodes.
```
kubectl apply -f kubevirt-config.yaml
```

The new PCIe device can then be consumed in new KubeVirt deployments.

### How to access the Rook Ceph web UI
On the workstation run in a separate shell:
```
kubectl port-forward "service/rook-ceph-mgr-dashboard" 8443 -n rook-ceph
```

Then the web UI is accessible through:
https://localhost:8443/

For the login credentials refer to
https://rook.io/docs/rook/v1.13/Storage-Configuration/Monitoring/ceph-dashboard/#login-credentials

For the Prometheus dashboard one can query the IP with
```
echo "http://$(kubectl -n rook-ceph -o jsonpath={.status.hostIP} get pod prometheus-rook-prometheus-0):30900"
```

### How to access the Longhorn web UI
On the workstation run in a separate shell:
```
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```
Then the web UI is accessible through:
http://localhost:8080

### KubeVirt - Uploading a new cloud image
Open port in a separate terminal on your workstation where the image
to upload is located
```
kubectl port-forward -n cdi service/cdi-uploadproxy 18443:443
```
In a second terminal upload the image
```
virtctl image-upload dv <image-name> --size=5Gi --image-path <image-path> --uploadproxy-url=https://127.0.0.1:18443 --storage-class longhorn --insecure --force-bind --volume-mode block --namespace <namespace>
```

If the image upload fails because of a too small size option, the PVCs and
related cdi-upload pod can be deleted with the following command:
```
kubectl delete datavolume <image-name>
```

### Querying the KubeVirt version:
```
kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}"
```

### Updating KubeVirt
READ THE DOCUMENTATION BEFORE TO BE SURE NOTHING CHANGED!
```
export RELEASE=v1.4.0
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml
```

### Execute virsh commands in virt-launcher pod
https://kubevirt.io/user-guide/debug_virt_stack/virsh-commands/

### Run an Ansible playbook within a KubeVirt VirtualMachineInstance
https://kubevirt.io/user-guide/virtual_machines/accessing_virtual_machines/

Add `$HOME/.ssh/virtctl-proxy-config`:
```
Host vmi/*
   ProxyCommand virtctl port-forward --stdio=true %h %p
Host vm/*
   ProxyCommand virtctl port-forward --stdio=true %h %p
```
And the virtual-inventory.yaml:
```
virtual_k8s_cluster_nodes:
  hosts:
    masternode:
      ansible_host: vmi/k8s-masternode
```
Then run on the machine where `virtctl ssh` commands to the virtual instances
can be made:
```
ansible-playbook -i virtual-inventory.yaml playbooks/ansible-hello-world.yaml --ask-vault-pass --ask-become-pass --ssh-common-args "-F $HOME/.ssh/virtctl-proxy-config"
```

Hint: Install qemu-guest-agent packages with Ansible playbooks if the inventory
contains VMs

With this virtctl-proxy-config one is able to use the system ssh to connect to
KubeVirt VMs instead of using virtctl:
```
ssh user@vmi/vmname.namespace -i $HOME/.ssh/identity -F $HOME/.ssh/virtctl-proxy-config
```
