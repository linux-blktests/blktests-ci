#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

export vm_name="vm-runner-${GITHUB_JOB}-${GITHUB_RUN_ID}"
export vm_user="fedora"
export ssh_options=(--identity-file=$(realpath ./identity | xargs) --local-ssh --local-ssh-opts="-o StrictHostKeyChecking=no")
