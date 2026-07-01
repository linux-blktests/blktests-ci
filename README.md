# blktests-ci

A collection of Ansible playbooks that bootstrap a Kubernetes cluster geared
towards kernel storage testing, with a focus on making PCIe devices available to
test VMs.

The project provides Continuous Integration (CI) infrastructure for blktests and
similar projects: it builds and tests a kernel on demand whenever a new
storage-related kernel contribution is proposed, on real hardware.

## Table of contents

- [Architecture](#architecture)
- [Getting started](#getting-started)
  - [Install workstation dependencies](#install-workstation-dependencies)
  - [Configure variables and secrets](#configure-variables-and-secrets)
  - [Declare PCIe passthrough devices](#declare-pcie-passthrough-devices)
  - [Install Kubernetes (k3s) on the nodes](#install-kubernetes-k3s-on-the-nodes)
  - [Connect kubectl to your workstation](#connect-kubectl-to-your-workstation)
  - [Install the Kubernetes CI requirements](#install-the-kubernetes-ci-requirements)
  - [Allow the workstation to use the private registry](#allow-the-workstation-to-use-the-private-registry)
- [Optional components](#optional-components)
  - [Corporate proxy (mitmproxy)](#corporate-proxy-mitmproxy)
  - [Kernel Patches Daemon (kpd)](#kernel-patches-daemon-kpd)
- [GitHub runner scale sets](#github-runner-scale-sets)
- [GitLab runners](#gitlab-runners)
- [Operations and reference](#operations-and-reference)
  - [CI binary cache](#ci-binary-cache)
  - [Access logs via Grafana Loki](#access-logs-via-grafana-loki)
  - [Use the private container registry](#use-the-private-container-registry)
  - [Download a VM image](#download-a-vm-image)
  - [Add PCIe passthrough devices](#add-pcie-passthrough-devices)
  - [Access the Rook Ceph dashboard](#access-the-rook-ceph-dashboard)
  - [Access the Longhorn dashboard](#access-the-longhorn-dashboard)
  - [Upload a new KubeVirt cloud image](#upload-a-new-kubevirt-cloud-image)
  - [Query the KubeVirt version](#query-the-kubevirt-version)
  - [Update KubeVirt](#update-kubevirt)
  - [Run virsh in a virt-launcher pod](#run-virsh-in-a-virt-launcher-pod)
  - [Run an Ansible playbook inside a KubeVirt VM](#run-an-ansible-playbook-inside-a-kubevirt-vm)
- [Roadmap](#roadmap)

## Architecture

The goal is to build and test a kernel on demand, triggered by a single CI
workflow that defines the exact kernel, the test to run and the physical devices
to run it on. To use the hardware efficiently, several different kernel test
workloads share the same pool of nodes, scheduled by Kubernetes.

A pre-registered self-hosted GitHub runner VM cannot simply pick up a workflow
and install or reboot into a new kernel: it would lose its connection to GitHub
and fail the workflow. Nested VMs would work around this but waste resources.
Instead, each job provisions a fresh KubeVirt VM on demand, boots the requested
kernel inside it, runs the test, and tears the VM down afterwards.

The following diagram illustrates the architecture:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./doc/blktests-ci-architecture-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./doc/blktests-ci-architecture-light.png">
  <img alt="blktests-ci architecture" src="./doc/blktests-ci-architecture-light.png">
</picture>

## Getting started

> [!WARNING]
> These playbooks are not production ready. Proceed with caution and expect the
> worst.

The setup was tested on a three-node cluster of Dell R6525 machines running
Ubuntu 22.04 (deployed via MAAS), connected with NVIDIA Mellanox ConnectX-6 Dx
SmartNICs and populated with several different NVMe SSDs for testing. Each node
has a 2 TB boot drive that also holds non-critical cluster storage.

A Linux distribution must already be installed on each node before you start.
Installing the bare-metal OS is out of scope for this project; tools such as
MAAS or Proxmox can handle it.

### Install workstation dependencies

Install the following on the machine you will orchestrate the cluster from
(referred to as the *workstation* throughout this guide):

- Python 3 and pip
- Ansible
- Docker (or Podman with podman-docker)
- kubectl
- helm
- virtctl (the version must match the KubeVirt version in `variables.yaml`; see
  the [official release](https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/))

The workstation needs network access to the cluster nodes.

### Configure variables and secrets

Review the entries in `variables.yaml`, then create the encrypted secrets file
and set the secret variables listed at the end of `variables.yaml`:

```
ansible-vault create secrets.enc
```

Do not commit `secrets.enc`. Edit it later with `ansible-vault edit secrets.enc`;
re-running the playbooks alone is not enough to change a secret value.

Copy the inventory template and fill in your node IPs:

```
cp k8s-inventory-template.yaml k8s-inventory.yaml
```

### Declare PCIe passthrough devices

The set of PCIe devices that KubeVirt VMs may use is declared once, in
`pciHostDevices` in
`playbooks/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml`. That list is
the single source of truth. The `configure-physical-k8s-cluster-node` play reads
it and binds every listed device to the `vfio-pci` driver on each node at boot,
by deriving a `vfio-pci.ids=...` kernel argument from it (together with the IOMMU
arguments for the node's CPU vendor). You do not edit the bootloader by hand.

Any vfio IDs already present on a node's running kernel command line are merged
in rather than overwritten, so manual or legacy entries and non-KubeVirt
passthrough devices survive. New devices only take effect after the node is
rebooted, so plan a reboot whenever you change `pciHostDevices`.

To add a device after the initial setup, see
[Add PCIe passthrough devices](#add-pcie-passthrough-devices).

### Install Kubernetes (k3s) on the nodes

Deploy a [k3s cluster](https://docs.k3s.io/quick-start) on the nodes.

On the first node:
```
#https://docs.k3s.io/datastore/ha-embedded
ufw disable
curl -sfL https://get.k3s.io | sh -s - server --nonroot-devices --cluster-init
cat /var/lib/rancher/k3s/server/node-token
```

On every other node:
```
ufw disable
# K3S_TOKEN can be found on the first node at /var/lib/rancher/k3s/server/node-token
curl -sfL https://get.k3s.io | K3S_TOKEN=<secret from first node> sh -s - server --nonroot-devices --server https://<ip or hostname of first node>:6443
```

The `--nonroot-devices` flag is required because Longhorn is later deployed on
the bare-metal cluster. It sets `device_ownership_from_security_context` in
containerd (see https://github.com/k3s-io/k3s/issues/11168).

### Connect kubectl to your workstation

Copy `/etc/rancher/k3s/k3s.yaml` from one of the cluster nodes to
`~/.kube/config` on your workstation and replace `127.0.0.1` with the cluster
node IP.

Verify the connection:
```
kubectl get nodes
```

### Install the Kubernetes CI requirements

Install the CI components provided by this project. Run this from the root of the
repository on your workstation:

```
ansible-playbook -i k8s-inventory.yaml playbooks/install-k8s-requirements.yaml --ask-vault-pass --ask-become-pass
```

Among other components, this deploys the in-cluster CI binary cache (see
[CI binary cache](#ci-binary-cache)), which serves version-matched `kubectl`,
`virtctl` and `logcli` to the runner jobs.

### Allow the workstation to use the private registry

This project self-hosts a container registry on the cluster for kernel builds and
other artifacts. The cluster was already configured to accept it by the previous
step; now configure the workstation to push and pull from it. Edit
`/etc/docker/daemon.json` on the workstation:

```
{
  "insecure-registries": ["<k8s-node-ip>:32000"]
}
```

Test the connection:
```
docker pull nginx:latest
docker tag nginx:latest <k8s-node-ip>:32000/nginx:latest
docker push <k8s-node-ip>:32000/nginx:latest
```

See [Use the private container registry](#use-the-private-container-registry) for
how to reference these images from Kubernetes manifests and docker-in-docker.

## Optional components

### Corporate proxy (mitmproxy)

If your cluster sits behind a corporate TLS-inspecting firewall, set
`corporate_ca_cert_path` in `variables.yaml` to the path of the corporate CA
certificate PEM file on the workstation. When this variable is defined, the
`install-k8s-requirements.yaml` playbook will:

1. Deploy mitmproxy as an in-cluster HTTPS proxy
   (`mitmproxy.mitmproxy.svc.cluster.local:8080`).
2. Generate a mitmproxy CA certificate and distribute it (via ConfigMap) to all
   ARC runners, KubeVirt VMs and the kernel-builder CronJob.
3. Configure proxy environment variables so all CI traffic is routed through
   mitmproxy, which handles upstream TLS verification using the corporate CA.

GitHub Actions workflows that run `docker build` against
`Dockerfile.linux-kernel-containerdisk` should pass proxy build args so the
Dockerfile can auto-discover the mitmproxy CA:

```yaml
docker build \
  --build-arg http_proxy \
  --build-arg https_proxy \
  --build-arg no_proxy \
  ...
```

No SSL verification is disabled anywhere; the mitmproxy CA certificate is
installed into the trust store of every component that needs it.

### Kernel Patches Daemon (kpd)

[kernel-patches-daemon](https://github.com/linux-blktests/kernel-patches-daemon/tree/blktests)
(kpd) watches patchwork for new series sent to the linux-block mailing list,
applies them on top of a GitHub repository and opens pull requests that trigger
CI workflows.

kpd is deployed automatically when `kpd_github_app_id` is defined in
`secrets.enc`. To enable it:

1. **Create a GitHub App.** In your organisation's GitHub settings, go to
   Developer settings -> GitHub Apps -> New GitHub App.
   - Pick a name; this becomes the PR bot's username.
   - Set the Homepage URL to your org's GitHub page.
   - Deactivate Webhooks.
   - Select these Repository permissions:
     - Contents: Read and write
     - Issues: Read and write
     - Pull requests: Read and write
     - Workflows: Read and write
   - Click "Create GitHub App".
   - Note the App ID for the `kpd_github_app_id` secret.
   - Scroll down, generate and note the private key for the
     `kpd_github_app_private_key` secret.
   - In the left menu hit "Install App" and click "Install" for the organisation
     you want to use.
   - Select repository access for `kpd_target_repo` and `kpd_lock_repo`.
   - Note the installation ID (last part of the URL) for
     `kpd_github_app_installation_id`.

2. **Create the lock repository** `linux-blktests/blktests-kpd-lock` (or
   whichever name is set in `kpd_lock_repo` in `variables.yaml`). It is used for
   cross-cluster leader election. The GitHub App must have Contents read/write
   access to this repository. Initialize it with a README or leave it empty; the
   lock file is created automatically.

3. **Add the secrets** to `secrets.enc` via `ansible-vault edit secrets.enc`:
   ```yaml
   kpd_github_app_id: "<app-id>"
   kpd_github_app_installation_id: <installation-id>
   kpd_github_app_private_key: |
     -----BEGIN RSA PRIVATE KEY-----
     ...
     -----END RSA PRIVATE KEY-----
   kpd_patchwork_api_username: "<patchwork-username>"
   kpd_patchwork_api_token: "<patchwork-api-token>"
   ```

4. **Set `kpd_cluster_name`** in `variables.yaml` to a unique name for each
   cluster (e.g. `cluster-west`, `cluster-east`). This identifies the cluster in
   the leader-election lock.

5. **Set SMTP credentials** (optional) in `secrets.enc` via
   `ansible-vault edit secrets.enc` for kpd email notifications.

#### Cross-cluster leader election

kpd can be deployed across multiple disjoint Kubernetes clusters with automatic
active/passive failover. Only one instance is active at a time; the others stay
on standby.

The leader election uses a file (`lock.json`) in the `kpd_lock_repo` GitHub
repository as a distributed lock:

- The active instance writes its cluster name and a timestamp to `lock.json`
  through the GitHub Contents API. GitHub's SHA-based compare-and-swap prevents
  concurrent writers.
- A heartbeat updates the timestamp every `kpd_heartbeat_interval_seconds`
  (default 300 s).
- Standby instances poll the lock. If the timestamp is older than
  `kpd_lock_ttl_seconds` (default 1200 s), a standby attempts a takeover.
- On graceful shutdown the active instance deletes the lock file, so failover is
  immediate.

#### Manual override

Set `kpd_active: false` in `variables.yaml` (or uncomment the existing line) to
force a cluster into permanent standby regardless of the lock state. This is
useful during maintenance. Re-run the playbook after changing the value.

## GitHub runner scale sets

The second main feature of this project is spawning GitHub Actions runner scale
sets, following the [architecture](#architecture) above, for different GitHub
projects.

ARC (Actions Runner Controller) authenticates against the GitHub API. Two methods
are supported (see the
[GitHub docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api)).
The playbook prompts for all credential fields and infers the method from which
fields you fill in:

| Provide | Result |
|---------|--------|
| GitHub App ID + Installation ID + private key path | GitHub App auth (recommended) |
| GitHub PAT | Personal access token auth |
| Nothing (leave all auth fields empty) | Reuses the existing `github-config-secret` in the namespace (useful for redeploying) |

### Option A: GitHub App authentication (recommended)

1. **Create a GitHub App** owned by your organisation. In your organisation's
   GitHub settings, go to Developer settings -> GitHub Apps -> New GitHub App.
   - Set the Homepage URL to
     `https://github.com/actions/actions-runner-controller`.
   - Deactivate Webhooks.
   - Under Repository permissions select:
     - Administration: Read and write (required when `githubConfigUrl` points to
       a repository, which is the typical setup)
     - Metadata: Read-only
   - Under Organization permissions select:
     - Self-hosted runners: Read and write
   - Click "Create GitHub App".
   - Note the App ID (you are prompted for it when running the playbook).
   - Scroll down, generate a private key and save the `.pem` file (you are
     prompted for its path).

2. **Install the App** on your organisation. In the left menu hit "Install App"
   and click "Install" for the organisation. Under "Repository access" select the
   repositories that the runner scale sets should serve (the repos used as
   `githubConfigUrl`). Note the installation ID (last number in the URL).

When running the playbook you are prompted for the App ID, Installation ID and
the path to the `.pem` private key file.

### Option B: Personal access token (PAT)

Generate a new fine-grained personal access token for the repository or
organization. Follow the
[GitHub guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token)
and make the following least-privilege choices (the token must be generated in
your personal settings while selecting the correct `Resource owner`):

```
For point 7   (Expiration) please select "No expiration" or the longest period
              possible.
For point 9   (Owner resource) please select the corresponding owning entity of
              the repository that should subscribe to the runner sets.
For point 11  (Repository access) please select "Only select repositories" and
              add ONLY the one repository that requires the self-hosted testing
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
  Workflow:       Read and write
```

Always share the token over a secure channel only.

### Repository configuration

Configuration required on the GitHub repository that uses the self-hosted runner
scale set (Repo -> Settings -> Actions -> General):

- Optionally restrict who may run Actions, under Actions permissions.
- Prevent PRs from running code on the self-hosted runner before approval: enable
  "Require approval for all outside collaborators".
- Restrict write access for the `GITHUB_TOKEN`: set "Read repository content and
  packages permissions".
- Prevent Actions from creating or approving pull requests: disable "Allow GitHub
  Actions to create and approve pull requests".
- In reviews, watch for code injection and secret leaks in workflows (see
  [security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)).

### Running the playbook

Run the following in the root of the repository and answer the prompts:
```
ansible-playbook -i k8s-inventory.yaml playbooks/setup-github-runner-scale-set.yaml
```

The playbook prompts for the runner set name, repo URL and authentication
credentials. Fill in either the GitHub App fields or the PAT field. Leave all
auth fields empty to reuse the existing `github-config-secret` (e.g. when
redeploying a runner scale set with updated configuration).

The runner scale set `arc-vm-<repo-name>` should now appear under
Repo -> Settings -> Actions -> Runners.

### Debugging

- ARC listeners: `kubectl get pods -n arc-systems`
- ARC pods for a repo: `kubectl get pods -n gh-runner-<repo-name>`
- VMs: `kubectl get vmi --all-namespaces`

### Deleting a runner scale set

```
helm delete arc-vm-<repo-name> -n gh-runner-<repo-name>
kubectl delete secret github-config-secret -n gh-runner-<repo-name>
#Double check that everything is deleted:
kubectl api-resources --verbs=list --namespaced -o name  | xargs -n 1 kubectl get --show-kind --ignore-not-found -n gh-runner-<repo-name>
kubectl delete ns gh-runner-<repo-name>
```

## GitLab runners

As an alternative to the GitHub ARC path above, the same on-demand KubeVirt
architecture can be driven from a (self-managed) GitLab instance. This is
implemented in parallel and does not affect the GitHub path: instead of the
Actions Runner Controller, it deploys the official GitLab Runner with the
Kubernetes executor, which provisions one ephemeral job pod per CI/CD job. Each
job pod runs as the same `kubevirt-actions-runner` service account and can
therefore spawn KubeVirt VMs.

The relevant variables live under the `#gitlab-runner` section of
`variables.yaml` (chart version, concurrency and the runner image name).

### Create a runner and obtain its token

GitLab 16+ uses runner authentication tokens (the legacy registration-token
workflow was removed in GitLab 18.0). Runner tags are configured in the UI when
the runner is created, not in the deployment (see the
[GitLab docs](https://docs.gitlab.com/ci/runners/runners_scope/#create-an-instance-runner-with-a-runner-authentication-token)):

1. In GitLab, go to your project (or group/instance) ->
   Settings -> Build (or CI/CD) -> Runners -> New runner.
2. Set the tags. Use the tags the playbook prints for your cluster; these are
   `kubevirt` plus one tag per PCI device that is both permitted by the KubeVirt
   CR and allocatable on a node (e.g. `nvme-wdc-zn540`).
3. Leave "Run untagged jobs" disabled so only `tags:`-matched jobs land on this
   runner.
4. Optionally lock the runner to the project and protect it.
5. Click "Create runner" and copy the runner authentication token (prefixed
   `glrt-`). You are prompted for it when running the playbook.

### Repository configuration

As with the GitHub path, harden the project so untrusted contributors cannot run
code on the self-hosted runner before review:

- Settings -> CI/CD -> Runners: only expose this runner to the intended
  project(s).
- Settings -> CI/CD -> General pipelines: require approval or restrict pipelines
  for merge requests from forks.
- Review `.gitlab-ci.yml` changes for code injection and secret leaks, the same
  way you would review GitHub workflows.

### Running the playbook

Run the following in the root of the repository and answer the prompts:
```
ansible-playbook -i k8s-inventory.yaml playbooks/setup-gitlab-runner-scale-set.yaml
```

The playbook prompts for the runner set name (the namespace becomes
`gl-runner-<name>`), the GitLab instance URL and the runner authentication token.
Leave the token empty to reuse the existing `gitlab-runner-secret` (e.g. when
redeploying with updated configuration). It also builds and pushes the
`kubevirt-runner` job image to the local registry.

The runner should now appear under your project's
Settings -> CI/CD -> Runners as online.

### Using the runner in a pipeline

Include the reusable KubeVirt CI template (the GitLab counterpart of the
`kubevirt-action` composite action) from the consuming project's `.gitlab-ci.yml`
and extend the hidden `.kubevirt` job:

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/linux-blktests/blktests-ci/main/ci/gitlab/kubevirt.gitlab-ci.yml'

blktests:
  extends: .kubevirt
  tags: [kubevirt, nvme-wdc-zn540]
  variables:
    KUBEVIRT_KERNEL_VERSION: "6.18.0"
    KUBEVIRT_HOST_DEVICES: "nvme-wdc-zn540,nvme-wdc-zn540"
    KUBEVIRT_ARTIFACT_UPLOAD_DIR: "results"
    KUBEVIRT_RUN_CMDS: |
      cd blktests && ./check block
```

Test results, dmesg logs and kernel artifacts are exposed as job `artifacts:`.

### Debugging

The runner manager and job pods live in the `gl-runner-<name>` namespace:
- Pods: `kubectl get pods -n gl-runner-<name>`
- VMs: `kubectl get vmi --all-namespaces`

### Deleting a GitLab runner

```
helm delete gitlab-runner-<name> -n gl-runner-<name>
kubectl delete secret gitlab-runner-secret -n gl-runner-<name>
#Double check that everything is deleted:
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n gl-runner-<name>
kubectl delete ns gl-runner-<name>
```
Also delete the runner in the GitLab UI (Settings -> CI/CD -> Runners).

## Operations and reference

### CI binary cache

The KubeVirt runner jobs need `kubectl`, `virtctl` and `logcli`. Instead of
downloading these from the internet on every job, they are cached in the cluster
and served over HTTP from the `ci-tools` namespace (deployed by the
`k8s-install-ci-binary-cache` role as part of `install-k8s-requirements.yaml`).

The cache is backed by a Longhorn volume and kept correct by a CronJob that
queries the live cluster and re-downloads a binary only when its version drifts:
`kubectl` is matched to the Kubernetes server version, `virtctl` to the observed
KubeVirt version, and `logcli` to the pinned `logcli_version` in `variables.yaml`.
The KubeVirt entrypoint fetches the binaries from
`http://ci-bin-cache.ci-tools.svc.cluster.local` (covered by the runner pods'
`NO_PROXY`, so mitmproxy is bypassed) and only falls back to a direct internet
download if the cache is unreachable.

Inspect or force-refresh the cache:
```
# Currently cached versions and binaries
kubectl exec -n ci-tools deploy/ci-bin-cache -- sh -c 'cat /usr/share/nginx/html/versions.json; ls -l /usr/share/nginx/html'
# Trigger an out-of-schedule reconcile
kubectl create job -n ci-tools --from=cronjob/ci-bin-cache-updater ci-bin-cache-manual
kubectl logs -n ci-tools job/ci-bin-cache-manual
```

### Access logs via Grafana Loki

On your workstation, fetch the admin password (change it on first login) and
forward the Grafana port:
```
kubectl get secret --namespace logging grafana -o jsonpath="{.data.admin-password}" | base64 --decode | xargs
kubectl port-forward service/grafana 3000:80 -n logging
```
Then open the dashboard at http://localhost:3000/.

Query logs through the Explore view with the Loki data source, or in Drilldown.

### Use the private container registry

After configuring the workstation (see
[Allow the workstation to use the private registry](#allow-the-workstation-to-use-the-private-registry)),
reference images in Kubernetes deployments through the k3s registry mirror:
`container-registry.local:5000/nginx:latest`.

In docker-in-docker (dind) deployments, refer to the registry like so:
`registry-service.docker-registry.svc.cluster.local`. For example, `daemon.json`:
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

### Download a VM image

You might need to issue this command several times until the vmexport timeout
stops canceling it. The image should be in raw format to be consumed by qemu, or
in a compressed format to reuse it with KubeVirt (see the virtctl manual).

```
#via shutoff vm
virtctl vmexport download vmexportname --vm <vm-name> --format raw --output=/path/to/vm-export.raw --port-forward
#or via snapshot:
virtctl vmexport download vmexportname --snapshot <vm-snapshot-name> --format raw --output=/path/to/vm-export.raw --port-forward
```

### Add PCIe passthrough devices

To add another device, edit and commit
`playbooks/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml` with a new
`pciHostDevices` entry. Use `lspci -n` to get the vendor and device ID of the
PCIe device that KubeVirt VMs should consume. See
[Declare PCIe passthrough devices](#declare-pcie-passthrough-devices) for how the
list is used.

You do not rebind the driver by hand. The `configure-physical-k8s-cluster-node`
play derives the `vfio-pci.ids=` kernel argument from the `pciHostDevices` list,
so once the new ID is in the manifest, re-run the host configuration to bind it to
`vfio-pci` on boot:
```
ansible-playbook -i k8s-inventory.yaml playbooks/install-k8s-requirements.yaml --ask-vault-pass --ask-become-pass
```
The new ID is merged into each node's kernel command line (existing IDs are
preserved); reboot the node for the kernel to actually bind the device to
`vfio-pci`. The play prints a reminder whenever a reboot is pending. The merge is
additive, so removing a device from `pciHostDevices` does not unbind it on the
host. To reclaim it, delete the ID from the node's kernel command line by hand
(the `/etc/default/grub.d/99-vfio-passthrough.cfg` drop-in on Debian, or
`grubby --remove-args` on RedHat) and reboot.

The same playbook run also re-applies the manifest to the running cluster so
KubeVirt permits the device. To update only the cluster side without touching the
host binding, apply it directly from one of the control nodes:
```
kubectl apply -f kubevirt-config.yaml
```

The new PCIe device can then be consumed in new KubeVirt deployments.

#### SMR HDDs behind SAS HBAs

Unlike the NVMe drives (e.g. the WDC ZN540), which are themselves PCIe endpoints
rebound to `vfio-pci` individually, an SMR / host-managed (ZBC) HDD is a SAS/SATA
disk sitting behind a SAS HBA. The PCIe endpoint is the HBA, not the disk, so
passthrough happens at HBA granularity: the whole controller, and every disk
attached to it, is handed to the VM.

To pass through an individual SMR disk, connect each SMR disk to its own HBA so
that per-HBA passthrough is equivalent to per-disk passthrough. When binding the
HBAs to `vfio-pci`, make sure that:
- each HBA you pass through sits in its own IOMMU group
  (`ls /sys/kernel/iommu_groups/`), and
- the OS / Longhorn storage disks are not attached to any HBA you bind (binding
  takes the disks away from the host).

The Broadcom/LSI SAS 9400-series Tri-Mode HBAs are already declared in
`kubevirt-config.yaml`, pooled under one resource name
(`devices.kubevirt.io/hba-broadcom-sas34xx`) because several models share a PCI
device ID and KubeVirt cannot tell them apart anyway. Confirm the IDs present on
your hosts with:
```
lspci -nn -d 1000:
```
Add any missing IDs to `pciHostDevices`; the host configuration play then binds
them to `vfio-pci` automatically by deriving `vfio-pci.ids=1000:00ac,...` from the
manifest (see above). A node reboot applies it.

Request the HBA like any other host device; the runner tag and `host_devices` /
`KUBEVIRT_HOST_DEVICES` plumbing is device-agnostic. Because the resource is a
pool, requesting it N times yields N (arbitrary) HBAs:
```yaml
blktests-smr:
  extends: .kubevirt
  tags: [kubevirt, hba-broadcom-sas34xx]
  variables:
    KUBEVIRT_HOST_DEVICES: "hba-broadcom-sas34xx"
    KUBEVIRT_RUN_CMDS: |
      cd blktests && ./check zbd
```
Inside the VM, the (generalized) `prepare-nvme-devices.sh` discovers any
host-managed/host-aware disk from `/sys/block/*/queue/zoned` and exports it as
`ZBD<N>` in `/etc/environment`, exactly like an NVMe ZNS namespace. The guest
kernel must provide `CONFIG_SCSI_MPT3SAS` and `CONFIG_BLK_DEV_ZONED`.

### Access the Rook Ceph dashboard

On the workstation, in a separate shell:
```
kubectl port-forward "service/rook-ceph-mgr-dashboard" 8443 -n rook-ceph
```
Then open https://localhost:8443/.

For login credentials, see the
[Rook docs](https://rook.io/docs/rook/v1.13/Storage-Configuration/Monitoring/ceph-dashboard/#login-credentials).

For the Prometheus dashboard, query the IP with:
```
echo "http://$(kubectl -n rook-ceph -o jsonpath={.status.hostIP} get pod prometheus-rook-prometheus-0):30900"
```

### Access the Longhorn dashboard

On the workstation, in a separate shell:
```
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```
Then open http://localhost:8080.

### Upload a new KubeVirt cloud image

In a separate terminal on the workstation where the image to upload is located,
open the upload proxy port:
```
kubectl port-forward -n cdi service/cdi-uploadproxy 18443:443
```
In a second terminal, upload the image:
```
virtctl image-upload dv <image-name> --size=5Gi --image-path <image-path> --uploadproxy-url=https://127.0.0.1:18443 --storage-class longhorn --insecure --force-bind --volume-mode block --namespace <namespace>
```

If the upload fails because the size option is too small, delete the PVCs and the
related cdi-upload pod:
```
kubectl delete datavolume <image-name>
```

### Query the KubeVirt version
```
kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}"
```

### Update KubeVirt

Read the documentation first to be sure nothing changed.
```
export RELEASE=v1.4.0
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml
```

### Run virsh in a virt-launcher pod

See the
[KubeVirt virsh guide](https://kubevirt.io/user-guide/debug_virt_stack/virsh-commands/).

### Run an Ansible playbook inside a KubeVirt VM

See the
[KubeVirt access guide](https://kubevirt.io/user-guide/virtual_machines/accessing_virtual_machines/).

Add `$HOME/.ssh/virtctl-proxy-config`:
```
Host vmi/*
   ProxyCommand virtctl port-forward --stdio=true %h %p
Host vm/*
   ProxyCommand virtctl port-forward --stdio=true %h %p
```
And `virtual-inventory.yaml`:
```
virtual_k8s_cluster_nodes:
  hosts:
    masternode:
      ansible_host: vmi/k8s-masternode
```
Then run, on a machine that can reach the VMs via `virtctl ssh`:
```
ansible-playbook -i virtual-inventory.yaml playbooks/<your-playbook>.yaml --ask-vault-pass --ask-become-pass --ssh-common-args "-F $HOME/.ssh/virtctl-proxy-config"
```

Hint: install the qemu-guest-agent package via your playbook if the inventory
contains VMs.

With this `virtctl-proxy-config` you can also use the system ssh to connect to
KubeVirt VMs instead of virtctl:
```
ssh user@vmi/vmname.namespace -i $HOME/.ssh/identity -F $HOME/.ssh/virtctl-proxy-config
```

## Roadmap

Known limitations and planned improvements:

- Make the VM resources configurable (e.g. through instance types). The
  kernel-builder scale set is currently limited to 4 CPUs and 8 Gi of memory.
- Make `pciHostDevices` configurable in `variables.yaml` instead of hard-coding
  it in `playbooks/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml`.
- Add an Ansible playbook for deploying k3s on the cluster nodes.
- Add an Ansible playbook for registering the self-hosted registry on the
  workstation in a non-destructive way.
- Add an Ansible playbook for deleting a runner scale set.
