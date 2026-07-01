#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)
#
# Reconcile the cached CI binaries (kubectl/virtctl/logcli) on the cache volume
# against the live cluster. A binary is (re)downloaded only when it is missing
# or its version has drifted. Run by the ci-bin-cache CronJob and the nginx
# warm-up initContainer; talks to the in-cluster API with the pod's service
# account token (no kubectl required).
set -eu

CACHE_DIR="${CACHE_DIR:-/cache}"
LOGCLI_VERSION="${LOGCLI_VERSION:-v3.6.2}"
API="https://kubernetes.default.svc"
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN="$(cat "$SA/token")"
CACERT="$SA/ca.crt"

# Tools we need that are not in the minimal ubuntu base. apt fetches over HTTP
# (GPG-verified), so this works through mitmproxy without extra TLS trust. We
# then refresh the trust store so curl trusts the mounted mitmproxy CA, if any
# (a no-op when mitmproxy is not deployed).
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates jq unzip >/dev/null
update-ca-certificates >/dev/null 2>&1 || true

# GET an API path with the service-account credentials.
api_get() {
  curl -fsSL --cacert "$CACERT" -H "Authorization: Bearer $TOKEN" "$API$1"
}

# Normalize a Kubernetes-style version to vMAJOR.MINOR.PATCH.
norm() {
  echo "$1" | sed -E 's/^(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

# Read a recorded version from the cache marker (empty if absent).
have() {
  [ -f "$CACHE_DIR/versions.json" ] && jq -r ".$1 // empty" "$CACHE_DIR/versions.json" 2>/dev/null || true
}

# Atomically place an executable downloaded from <url> ($1) at $CACHE_DIR/<name>
# ($2). The temp file is created on the cache volume itself so the rename is an
# atomic same-filesystem operation and the nginx reader never observes a
# half-written binary (a cross-device mv would be a non-atomic copy).
install_url() {
  tmp="$(mktemp "$CACHE_DIR/.dl.XXXXXX")"
  curl -fsSL -o "$tmp" "$1"
  chmod 0755 "$tmp"
  mv -f "$tmp" "$CACHE_DIR/$2"
}

mkdir -p "$CACHE_DIR"
# Drop any temp files left behind by a previously interrupted run.
rm -f "$CACHE_DIR"/.dl.* "$CACHE_DIR"/.versions.json.* 2>/dev/null || true

# Desired versions, queried from the live cluster. The server version is
# mandatory: a failed query aborts the run (set -e) so it is retried and stays
# visible rather than silently emptying the cache. The KubeVirt CR is optional
# (absent until KubeVirt is installed), in which case virtctl is left untouched.
server_version="$(api_get /version)"
kubectl_want="$(norm "$(printf '%s' "$server_version" | jq -r '.gitVersion // empty')")"
kubevirt_cr="$(api_get /apis/kubevirt.io/v1/namespaces/kubevirt/kubevirts/kubevirt 2>/dev/null)" || kubevirt_cr=""
virtctl_want="$(printf '%s' "$kubevirt_cr" | jq -r '.status.observedKubeVirtVersion // empty')"
logcli_want="$LOGCLI_VERSION"

if [ -n "$kubectl_want" ] && { [ ! -f "$CACHE_DIR/kubectl" ] || [ "$(have kubectl)" != "$kubectl_want" ]; }; then
  echo "kubectl: updating to $kubectl_want (cached: $(have kubectl))"
  install_url "https://dl.k8s.io/release/${kubectl_want}/bin/linux/amd64/kubectl" kubectl
fi

if [ -n "$virtctl_want" ] && { [ ! -f "$CACHE_DIR/virtctl" ] || [ "$(have virtctl)" != "$virtctl_want" ]; }; then
  echo "virtctl: updating to $virtctl_want (cached: $(have virtctl))"
  install_url "https://github.com/kubevirt/kubevirt/releases/download/${virtctl_want}/virtctl-${virtctl_want}-linux-amd64" virtctl
fi

if [ -n "$logcli_want" ] && { [ ! -f "$CACHE_DIR/logcli" ] || [ "$(have logcli)" != "$logcli_want" ]; }; then
  echo "logcli: updating to $logcli_want (cached: $(have logcli))"
  tmpd="$(mktemp -d)"
  curl -fsSL -o "$tmpd/logcli.zip" "https://github.com/grafana/loki/releases/download/${logcli_want}/logcli-linux-amd64.zip"
  unzip -o "$tmpd/logcli.zip" -d "$tmpd" >/dev/null
  # Publish onto the cache volume via a same-filesystem atomic rename.
  tmp="$(mktemp "$CACHE_DIR/.dl.XXXXXX")"
  cat "$tmpd/logcli-linux-amd64" > "$tmp"
  chmod 0755 "$tmp"
  mv -f "$tmp" "$CACHE_DIR/logcli"
  rm -rf "$tmpd"
fi

# Record the resolved versions (keep the previous value when a want is empty,
# e.g. KubeVirt not yet installed so virtctl could not be resolved). Written via
# a temp + atomic rename so a concurrent reader never sees partial JSON.
jq -n \
  --arg kubectl "${kubectl_want:-$(have kubectl)}" \
  --arg virtctl "${virtctl_want:-$(have virtctl)}" \
  --arg logcli  "${logcli_want:-$(have logcli)}" \
  '{kubectl:$kubectl, virtctl:$virtctl, logcli:$logcli}' > "$CACHE_DIR/.versions.json.tmp"
mv -f "$CACHE_DIR/.versions.json.tmp" "$CACHE_DIR/versions.json"

echo "cache ready: $(cat "$CACHE_DIR/versions.json")"
ls -l "$CACHE_DIR"
