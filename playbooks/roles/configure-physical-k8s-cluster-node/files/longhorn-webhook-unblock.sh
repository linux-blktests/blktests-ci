#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Managed by Ansible (configure-physical-k8s-cluster-node role).
#
# Purpose: break the Longhorn admission-webhook bootstrap deadlock that can brick
# the whole cluster after a full (all-nodes-at-once) reboot.
#
# The deadlock:
#   * Longhorn registers validating/mutating webhooks with failurePolicy=Fail whose
#     rules cover the *core* "nodes" resource, served by the
#     longhorn-system/longhorn-admission-webhook service.
#   * After a full reboot every pod is down, so that service has no endpoints.
#   * With failurePolicy=Fail the API server then rejects *every* Node update.
#   * k3s's embedded flannel must write its flannel.alpha.coreos.com/* annotations
#     onto the Node object to start. That write is rejected, so flannel never
#     initializes: /run/flannel/subnet.env is never created and no flannel.1/cni0
#     device comes up.
#   * Without flannel, no pod gets a network sandbox -> Longhorn can never start ->
#     the webhook never gets endpoints. Self-reinforcing; a plain k3s restart does
#     not help.
#
# Mitigation: early on boot, relax the Longhorn webhooks to failurePolicy=Ignore so
# Node updates are allowed through and flannel can initialize. Once Longhorn is
# healthy again it restores failurePolicy=Fail on its own, so there is nothing to
# undo here.
set -u

KUBECONFIG_FILE=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG="${KUBECONFIG_FILE}"
KUBECTL=(k3s kubectl)

log() { echo "[longhorn-webhook-unblock] $*"; }

# Only act on k3s server nodes (those with a local apiserver / kubeconfig).
if [ ! -f "${KUBECONFIG_FILE}" ]; then
  log "no k3s kubeconfig at ${KUBECONFIG_FILE}; not a server node, nothing to do"
  exit 0
fi

# Wait for the local apiserver to answer. Reads / webhook-config writes are NOT
# blocked by the Longhorn webhook (it only intercepts its listed resources), so
# this succeeds even while the Node-update deadlock is in effect.
for _ in $(seq 1 120); do
  if "${KUBECTL[@]}" get --raw='/readyz' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

relax() { # $1=resource kind  $2=name
  local kind="$1" name="$2"
  if ! "${KUBECTL[@]}" get "${kind}" "${name}" >/dev/null 2>&1; then
    return 0
  fi
  # Set failurePolicy=Ignore on every webhook entry in the configuration.
  local n i
  n="$("${KUBECTL[@]}" get "${kind}" "${name}" -o jsonpath='{range .webhooks[*]}{"x"}{end}' 2>/dev/null | wc -c)"
  for (( i=0; i<n; i++ )); do
    "${KUBECTL[@]}" patch "${kind}" "${name}" --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/webhooks/${i}/failurePolicy\",\"value\":\"Ignore\"}]" \
      >/dev/null 2>&1 || true
  done
  log "relaxed ${kind}/${name} -> failurePolicy=Ignore (Longhorn restores Fail once healthy)"
}

relax validatingwebhookconfiguration longhorn-webhook-validator
relax mutatingwebhookconfiguration  longhorn-webhook-mutator

# If flannel still has not produced its subnet file shortly after relaxing the
# webhooks, the k3s agent most likely gave up writing its node annotations before
# we got here. Restart k3s once so flannel re-runs now that Node updates succeed.
for _ in $(seq 1 24); do
  if [ -f /run/flannel/subnet.env ]; then
    log "flannel subnet.env present; pod networking is up"
    exit 0
  fi
  sleep 5
done

log "flannel subnet.env still missing after relaxing webhooks; restarting k3s once"
systemctl restart k3s || true
exit 0
