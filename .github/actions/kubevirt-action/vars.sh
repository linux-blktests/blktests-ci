#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

# Build a unique, DNS-1123-safe VM name that also embeds the repository
# org/name for easier triage (e.g. `kubectl get vmi -A`). GitHub Actions and
# GitLab CI expose different predefined variables. The trailing CI identifiers
# guarantee uniqueness, so the (sanitized) repository slug is the part that gets
# truncated to keep the whole name within Kubernetes' 63-character limit.
sanitize_k8s_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

if [ -n "${GITLAB_CI:-}" ]; then
  # CI_JOB_ID is unique per job, including each leg of a parallel matrix job.
  repo_slug="$(sanitize_k8s_name "${CI_PROJECT_PATH:-}")"
  vm_suffix="$(sanitize_k8s_name "${CI_PIPELINE_ID:-}-${CI_JOB_ID:-}")"
else
  repo_slug="$(sanitize_k8s_name "${GITHUB_REPOSITORY:-}")"
  vm_suffix="$(sanitize_k8s_name "${GITHUB_JOB:-}-${GITHUB_RUN_ID:-}")"
  # GITHUB_JOB (the job id) and GITHUB_RUN_ID are identical for every leg of a
  # strategy matrix, so this suffix alone collides across legs.
  # RUNNER_NAME is the ephemeral runner pod name under Actions Runner Controller:
  # unique per leg and deterministic across all of this job's steps.
  if [ -n "${RUNNER_NAME:-}" ]; then
    leg_hash="$(printf '%s' "${RUNNER_NAME}" | sha1sum | cut -c1-8)"
    vm_suffix="${vm_suffix}-${leg_hash}"
  fi
fi

# "vm-runner-" (10) + repo_slug + "-" (1) + vm_suffix must be <= 63 characters.
max_repo_len=$(( 63 - 11 - ${#vm_suffix} ))
if [ "${max_repo_len}" -gt 0 ] && [ -n "${repo_slug}" ]; then
  repo_slug="$(printf '%s' "${repo_slug}" | cut -c1-"${max_repo_len}" | sed -E 's/-+$//')"
  export vm_name="vm-runner-${repo_slug}-${vm_suffix}"
else
  export vm_name="vm-runner-${vm_suffix}"
fi
# Every VM provisions its own dedicated login user via cloud-init, so the SSH
# user is fixed regardless of the base image's default cloud user.
export vm_user="runner"
export ssh_options=(--identity-file=$(realpath ./identity | xargs) --local-ssh-opts="-o StrictHostKeyChecking=no")

# Container disk image backing the VM's root volume. Optional override exposed
# to both CI providers (GitHub: the `container_disk_image` action input; GitLab:
# the `KUBEVIRT_CONTAINER_DISK_IMAGE` variable), both surfaced here as
# INPUT_CONTAINER_DISK_IMAGE. When left empty the VM template falls back to its
# pinned default.
export container_disk_image="${INPUT_CONTAINER_DISK_IMAGE:-}"

# Distro family of the base image. It selects the package manager and CA-trust
# layout used to provision the VM, and the root device/flags for custom-kernel
# boots. It is inferred from the container disk image reference (matching the
# quay.io/containerdisks naming) but can be overridden with the `distro` input
# (INPUT_DISTRO) for mirrored or renamed images. Defaults to fedora if
# undecided.
detect_distro() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *fedora*) echo fedora ;;
    *ubuntu*) echo ubuntu ;;
    *debian*) echo debian ;;
    *opensuse*|*suse*|*tumbleweed*|*leap*|*microos*) echo opensuse ;;
    *) echo fedora ;;
  esac
}
export distro="${INPUT_DISTRO:-$(detect_distro "${container_disk_image}")}"

# Optional overrides for the root filesystem location the custom kernel boots
# from (only used when kernel_version is set). Empty means "use the per-distro
# default baked into the VM template".
export root_device="${INPUT_ROOT_DEVICE:-}"
export root_flags="${INPUT_ROOT_FLAGS:-}"
