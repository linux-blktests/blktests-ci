#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -e
set -x

# The containerDisk holds its disk under /disk with a name that depends on the
# distro and variant it was built for, so pick up whatever is in there instead
# of hardcoding a file name.
IMAGE=$(find /base-disk -maxdepth 1 -type f | head -n1)
if [ -z "$IMAGE" ]; then
  echo "error: no disk image found in /base-disk" >&2
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
copy-out /boot/${CONFIG_FILE} /
copy-out /boot/${INITRAMFS_FILE} /
EOF

mv "/${CONFIG_FILE}" /base-kernel-config
mv "/${INITRAMFS_FILE}" /base-initramfs.cpio.gz
