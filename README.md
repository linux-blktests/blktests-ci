# blktests-ci
This is a collection of Ansible scripts to help bootstrap a k8s cloud
environment with the focus on making PCIe devices available for testing.

This project adds automated infrastructure for Continuous Integration (CI) to
blktests and other projects, allowing to automatically execute the test suite
when new storage related kernel contributions are proposed.

### 📝TODOs
- kernel-builder-scale set is limited to 4 cpus and 8Gi memory
  -> this should be configurable
- Make the VM resources configurable (eg through instance types)

## Architecture
To achieve maximal flexibility and good resource utilization we decided to
build a Kubernetes infrastructure that is capable of running multiple different
kernel test workloads on the same set of hardware resources.

The requirements for kernel testing are that we want to build and test a kernel
on demand triggered by a single GitHub workflow.
This workflow defines the exact kernel, test and on which physical devices
the tests should be run on.

We can't use a pre-registered self-hosted GitHub runner VM to simply
pick up a workflow and install/reboot a new kernel because it would lose
connection and fail the workflow. Nested VMs would be a possible solution,
however, it lacks the good resource utilization.

This figure illustrates the architecture:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./doc/blktests-ci-architecture-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./doc/blktests-ci-architecture-light.png">
  <img alt="Fallback image description" src="./doc/blktests-ci-architecture-light.png">
</picture>

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

- Python3 and Python3-pip
- Ansible
- Docker (or Podman in combination with podman-docker)
- kubectl
- helm
- virtctl (version must match with definition in `variables.yaml`)
  (eg. [via the official release](https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/))

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

### Corporate proxy / mitmproxy (optional)
If your cluster sits behind a corporate TLS-inspecting firewall, set
`corporate_ca_cert_path` in `variables.yaml` to the path of the corporate CA
certificate PEM file on the workstation. When this variable is defined, the
`install-k8s-requirements.yaml` playbook will:

1. Deploy **mitmproxy** as an in-cluster HTTPS proxy
   (`mitmproxy.mitmproxy.svc.cluster.local:8080`).
2. Generate a mitmproxy CA certificate and distribute it (via ConfigMap) to
   all ARC runners, KubeVirt VMs and the kernel-builder CronJob.
3. Configure proxy environment variables so that all CI traffic is routed
   through mitmproxy, which handles upstream TLS verification using the
   corporate CA.

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

No SSL verification is disabled anywhere; the mitmproxy CA cert is installed
into the trust store of every component that needs it.

### Kernel Patches Daemon / kpd (optional)
[kernel-patches-daemon](https://github.com/linux-blktests/kernel-patches-daemon/tree/blktests)
(kpd) watches patchwork for new series sent to the linux-block mailing list,
applies them on top of a GitHub repository and creates pull requests that
trigger CI workflows.

kpd is deployed automatically when `kpd_github_app_id` is defined in
`secrets.enc`. To enable it:
g
1. **Create a GitHub App**:
   Navigate to your organisation's GitHub settings -> Developer settings ->
   GitHub Apps -> New GitHub App
   - Pick a name. This will be the PR bots username
   - Set the Homepage URL to your org's GitHub page
   - Deactivate Webhooks
   - Select the following Repository permissions:
      - Contents: Read and write
      - Issues: Read and write
      - Pull requests: Read and write
      - Workflows: Read and write
   - Click "Create GitHub App"
   - Note the App ID for the kpd_github_app_id secret
   - Scroll down, generate and note the private key for the
     kpd_github_app_private_key secret
   - In the left menu hit "Install APP" and klick "Install" for the
     organisation you want to use. -> Install
  - Select Repository access for kpd_target_repo and kpd_lock_repo
  - Note down the installation ID (last part of the URL) for
    kpd_github_app_installation_id

2. **Create the lock repository** `linux-blktests/blktests-kpd-lock` (or
   whichever name is set in `kpd_lock_repo` in `variables.yaml`). This
   repository is used for cross-cluster leader election. The GitHub App must
   also have Contents read/write access to this repository. Initialize the
   repository with a README or leave it empty — the lock file will be created
   automatically.

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
   cluster (e.g. `cluster-west`, `cluster-east`). This identifies the cluster
   in the leader election lock.

5. **Set SMTP credentials** (optional) in `secrets.enc` via
   `ansible-vault edit secrets.enc` for KPD email notifications.

#### Cross-cluster leader election

kpd supports deployment across multiple disjoint Kubernetes clusters with
automatic active/passive failover. Only one instance is active at a time;
the others remain in standby.

The leader election uses a file (`lock.json`) in the `kpd-lock` GitHub
repository as a distributed lock:

- The active instance writes its cluster name and a timestamp to
  `lock.json` using the GitHub Contents API. GitHub's SHA-based
  compare-and-swap prevents concurrent writers.
- A heartbeat updates the timestamp every `kpd_heartbeat_interval_seconds`
  (default 30 s).
- Standby instances poll the lock. If the timestamp is older than
  `kpd_lock_ttl_seconds` (default 120 s), a standby attempts a takeover.
- On graceful shutdown the active instance deletes the lock file so
  failover is immediate.

#### Manual override

Set `kpd_active: false` in `variables.yaml` (or uncomment the existing
line) to force a cluster into permanent standby regardless of the lock
state. This is useful during maintenance. Re-run the playbook after
changing the value.

Now is a great time to check on the cluster nodes that all PCIe devices that
shall be passed to KubeVirt VMs (for CI testing) are rebound to the vfio
driver on every startup (e.g. through kernel arguments).

Next make sure to adjust the `kubevirt-config.yaml` to define the same PCIe
devices from last step in `pciHostDevices`:
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
ansible-playbook -i k8s-inventory.yaml playbooks/install-k8s-requirements.yaml --ask-vault-pass --ask-become-pass
```

Among other components this also deploys the in-cluster CI binary cache (see
[CI binary cache](#ci-binary-cache) below), which serves version-matched
`kubectl`/`virtctl`/`logcli` to the runner jobs.

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

ARC needs to authenticate against the GitHub API. Two methods are supported
(see [GitHub docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api)).
The playbook prompts for all credential fields; the authentication method is
**inferred automatically** from which fields you fill in:

| Provide | Result |
|---------|--------|
| GitHub App ID + Installation ID + private key path | **GitHub App** auth (recommended) |
| GitHub PAT | **Personal Access Token** auth |
| Nothing (leave all auth fields empty) | Reuses the existing `github-config-secret` in the namespace (useful for redeploying) |

### Option A — GitHub App authentication (recommended)

1. **Create a GitHub App** owned by your organisation:
   Navigate to your organisation's GitHub settings -> Developer settings ->
   GitHub Apps -> New GitHub App.
   - Set the Homepage URL to
     `https://github.com/actions/actions-runner-controller`
   - Deactivate Webhooks
   - Under **Repository permissions** select:
     - Administration: Read and write (required when `githubConfigUrl`
       points to a repository, which is the typical setup)
     - Metadata: Read-only
   - Under **Organization permissions** select:
     - Self-hosted runners: Read and write
   - Click "Create GitHub App"
   - Note the **App ID** (you will be prompted for it when running the
     playbook)
   - Scroll down, generate a **private key** and save the `.pem` file
     (you will be prompted for its path)

2. **Install the App** on your organisation:
   In the left menu hit "Install App" and click "Install" for the
   organisation. Under "Repository access" select the repositories that
   the runner scale sets should serve (the repos used as `githubConfigUrl`).
   Note the **installation ID** (last number in the URL).

When running the playbook you will be prompted for the **App ID**,
**Installation ID** and the **path to the `.pem` private key file**.

### Option B — Personal Access Token (PAT)

Generate a new fine-grained personal access token for the repository or
organization. Follow the steps from
[here](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token)
and make the following least privilege choices (the token must be generated
within the personal settings while selecting the correct `Resource owner`):

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

### Repository configuration

Configuration required by the GitHub repo that uses the self-hosted runner
scale set:
- Optionally: Prevent group of people to allow actions:
Repo -> Settings -> Actions -> General -> Actions permissions
- Prevent PR's to execute code on self-hosted runner before getting approved:
Repo -> Settings -> Actions -> General -> 'Require approval for all outside
collaborators' -> Save
- Restrict write access to the repository with the GITHUB_TOKEN:
Repo -> Settings -> Actions -> General -> 'Read repository content and packages
permissions' -> Save
- Preventing GitHub Actions from creating or approving pull requests through the
GITHUB_TOKEN:
Repo -> Settings -> Actions -> General -> DISABLE 'Allow GitHub Actions to
create and approve pull requests' -> Save
- In reviews watch out for code injection and secret leaks within workflows
(https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)
In the repository->settings->actions->general->workflow

### Running the playbook

Run the following command in the root of this repository and answer the
prompts to create the runner scale sets:
```
ansible-playbook -i k8s-inventory.yaml playbooks/setup-github-runner-scale-set.yaml
```

The playbook will prompt for the runner set name, repo URL and authentication
credentials. Fill in either the GitHub App fields **or** the PAT field.
Leave all auth fields empty to reuse the existing `github-config-secret`
(e.g. when redeploying a runner scale set with updated configuration).

The runner scale sets `arc-vm-<repo-name>` should now be visible in the
Repo->Settings->Actions->Runners overview.

### Debug help
ARC listeners can be inspected via `kubectl get pods -n arc-systems`.
ARC related pods can be inspected via `kubectl get pods -n gh-runner-<repo-name>`.
VMs can be inspected via `kubectl get vmi --all-namespaces`.
VM templates can be inspected via `kubectl get vmi --all-namespaces`.

### Deleting a runner scale set

```
helm delete arc-vm-<repo-name> -n gh-runner-<repo-name>
kubectl delete secret github-config-secret -n gh-runner-<repo-name>
#Double check that everything is deleted:
kubectl api-resources --verbs=list --namespaced -o name  | xargs -n 1 kubectl get --show-kind --ignore-not-found -n gh-runner-<repo-name>
kubectl delete ns gh-runner-<repo-name>
```

---

#### 📝TODO

- Create Ansible script for deleting a runner scale set

---

## Creating GitLab runners (alternative to GitHub)

In addition to the GitHub ARC path above, the same KubeVirt-on-demand
architecture can be driven from a (self-managed) GitLab instance. This is
implemented in parallel and does not affect the GitHub path: instead of the
Actions Runner Controller, it deploys the official **GitLab Runner** with the
**Kubernetes executor**, which provisions one ephemeral job pod per CI/CD job.
Each job pod runs as the same `kubevirt-actions-runner` service account and can
therefore spawn KubeVirt VMs.

The relevant variables live under the `#gitlab-runner` section of
`variables.yaml` (chart version, concurrency and the runner image name).

### Create a runner and obtain its authentication token

GitLab 16+ uses runner authentication tokens (the legacy registration-token
workflow was removed in GitLab 18.0). Runner **tags are configured in the UI**
when the runner is created, not in the deployment
(https://docs.gitlab.com/ci/runners/runners_scope/#create-an-instance-runner-with-a-runner-authentication-token):

1. In GitLab navigate to your project (or group/instance) ->
   **Settings -> Build (or CI/CD) -> Runners -> New runner**.
2. Set the **tags**. Use the tags the playbook prints for your cluster — these
   are `kubevirt` plus one tag per PCI device that is both permitted by the
   KubeVirt CR and allocatable on a node (e.g. `nvme-wdc-zn540`).
3. Leave **Run untagged jobs** disabled so only `tags:`-matched jobs land on
   this runner.
4. Optionally lock the runner to the project and protect it.
5. Click **Create runner** and copy the **runner authentication token**
   (prefixed `glrt-`). You are prompted for it when running the playbook.

### Repository configuration

As with the GitHub path, harden the project so untrusted contributors cannot
execute code on the self-hosted runner before review:
- **Settings -> CI/CD -> Runners**: only expose this runner to the intended
  project(s).
- **Settings -> CI/CD -> General pipelines**: require approval / restrict
  pipelines for merge requests from forks.
- Review `.gitlab-ci.yml` changes for code injection and secret leaks, the same
  way you would review GitHub workflows.

### Running the playbook

Run the following in the root of this repository and answer the prompts:
```
ansible-playbook -i k8s-inventory.yaml playbooks/setup-gitlab-runner-scale-set.yaml
```

The playbook prompts for the runner set name (the namespace becomes
`gl-runner-<name>`), the GitLab instance URL and the runner authentication
token. Leave the token empty to reuse the existing `gitlab-runner-secret`
(e.g. when redeploying with updated configuration). It also builds and pushes
the `kubevirt-runner` job image to the local registry.

The runner should now appear under your project's
**Settings -> CI/CD -> Runners** as online.

### Using the runner from a pipeline

Include the reusable KubeVirt CI template (the GitLab counterpart of the
`kubevirt-action` composite action) from the consuming project's
`.gitlab-ci.yml` and extend the hidden `.kubevirt` job:

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

### Debug help
The runner manager and job pods live in the `gl-runner-<name>` namespace:
`kubectl get pods -n gl-runner-<name>`.
VMs can be inspected via `kubectl get vmi --all-namespaces`.

### Deleting a GitLab runner

```
helm delete gitlab-runner-<name> -n gl-runner-<name>
kubectl delete secret gitlab-runner-secret -n gl-runner-<name>
#Double check that everything is deleted:
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n gl-runner-<name>
kubectl delete ns gl-runner-<name>
```
Also delete the runner in the GitLab UI (Settings -> CI/CD -> Runners).

---

## Further notes and tips
### CI binary cache
The kubevirt runner jobs need `kubectl`, `virtctl` and `logcli`. Instead of
downloading these from the internet on every job, they are cached in the cluster
and served over HTTP from the `ci-tools` namespace (deployed by the
`k8s-install-ci-binary-cache` role as part of `install-k8s-requirements.yaml`).

The cache is backed by a Longhorn volume and kept correct by a `CronJob` that
queries the live cluster and re-downloads a binary only when its version drifts:
`kubectl` is matched to the Kubernetes server version, `virtctl` to the observed
KubeVirt version, and `logcli` to the pinned `logcli_version` in
`variables.yaml`. The kubevirt entrypoint fetches the binaries from
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

### Accessing logs through Grafana Loki
On your workstation query the admin password, which you should change on the
first login, and forward the port for Grafana:
```
kubectl get secret --namespace logging grafana -o jsonpath="{.data.admin-password}" | base64 --decode | xargs
kubectl port-forward service/grafana 3000:80 -n logging
```
Then you can access the Grafana dashboard via:
http://localhost:3000/

Logs can be queried though the Explorer with the Loki data source or in
'Drilldown'.

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
