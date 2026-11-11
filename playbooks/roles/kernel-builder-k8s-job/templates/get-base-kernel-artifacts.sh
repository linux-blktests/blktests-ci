#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -e
set -x

BUILD_ROOT="${BUILD_ROOT:-}"

# The containerDisk holds its disk under /disk with a name that depends on the
# distro and variant it was built for, so pick up whatever is in there instead
# of hardcoding a file name.
IMAGE=$(find "${BUILD_ROOT}/base-disk" -maxdepth 1 -type f | head -n1)
if [ -z "$IMAGE" ]; then
  echo "error: no disk image found in ${BUILD_ROOT}/base-disk" >&2
  exit 1
fi

export LIBGUESTFS_BACKEND=direct

FILES=$(guestfish --ro -a "$IMAGE" -i ls /boot)

CONFIG_FILE=$(echo "$FILES" | grep '^config-' | head -n1)
INITRAMFS_FILE=$(echo "$FILES" | grep '^initramfs-' | head -n1)

if [ -z "$CONFIG_FILE" ] || [ -z "$INITRAMFS_FILE" ]; then
  echo "error: no kernel config and initramfs found in /boot of ${IMAGE}" >&2
  exit 1
fi

guestfish --ro -a "$IMAGE" -i <<EOF
  copy-out /boot/${CONFIG_FILE} "${BUILD_ROOT:-/}"
  copy-out /boot/${INITRAMFS_FILE} "${BUILD_ROOT:-/}"
EOF

mv "${BUILD_ROOT}/${CONFIG_FILE}" "${BUILD_ROOT}/base-kernel-config"
mv "${BUILD_ROOT}/${INITRAMFS_FILE}" "${BUILD_ROOT}/base-initramfs.cpio.gz"
