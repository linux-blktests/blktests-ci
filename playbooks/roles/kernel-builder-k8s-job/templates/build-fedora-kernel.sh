#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -e
set -x
dockerd --host=unix:///var/run/docker.sock --group=123 &
KERNEL_TREE=https://github.com/torvalds/linux
KERNEL_COMMIT_SHA=master
docker build \
  --build-arg KERNEL_TREE=${KERNEL_TREE} \
  --build-arg KERNEL_COMMIT_SHA=${KERNEL_COMMIT_SHA} \
  -t linux-kernel-containerdisk \
  -f Dockerfile.linux-kernel-containerdisk . 2>&1 | tee build.log
#Setting KERNEL_VERSION var which is latern needed for notifying the VM what kernel to pick up
export $(cat build.log | grep KERNEL_VERSION | awk '{print $3}' | grep KERNEL_VERSION | xargs)
echo $KERNEL_VERSION
docker tag linux-kernel-containerdisk registry-service.docker-registry.svc.cluster.local/linux-kernel-containerdisk:${KERNEL_VERSION}
docker push registry-service.docker-registry.svc.cluster.local/linux-kernel-containerdisk:${KERNEL_VERSION}

