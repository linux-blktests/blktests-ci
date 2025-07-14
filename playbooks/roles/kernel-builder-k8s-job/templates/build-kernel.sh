#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -e
set -x

cd /
mkdir -p /linux
cd /linux
git init
git remote add origin $KERNEL_TREE
git fetch origin --depth=5 "${KERNEL_REF}"
git checkout FETCH_HEAD
git log -1

cp /base-kernel-config /linux/.config
yes "" | make olddefconfig
./scripts/config --disable CONFIG_MODULE_SIG
./scripts/config --disable CONFIG_MODULE_SIG_ALL
./scripts/config --enable CONFIG_BTRFS_FS
./scripts/config --enable CONFIG_BTRFS_FS_POSIX_ACL
./scripts/config --enable CONFIG_PSI
./scripts/config --enable CONFIG_MEMCG
./scripts/config --enable CONFIG_CRYPTO_LZO
./scripts/config --enable CONFIG_ZRAM
./scripts/config --enable CONFIG_ZRAM_DEF_COMP_LZORLE
./scripts/config --enable CONFIG_ISO9660_FS
./scripts/config --enable CONFIG_VFAT_FS
./scripts/config --enable CONFIG_NET_9P
./scripts/config --enable CONFIG_NET_9P_VIRTIO
./scripts/config --enable CONFIG_9P_FS
./scripts/config --enable CONFIG_9P_FS_POSIX_ACL
./scripts/config --enable CONFIG_VIRTIO
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_PCI
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_NET
./scripts/config --enable CONFIG_FUSE_FS
./scripts/config --enable CONFIG_VIRTIO_FS
./scripts/config --enable CONFIG_IKCONFIG
./scripts/config --enable CONFIG_IKCONFIG_PROC
./scripts/config --module CONFIG_BLK_DEV_NULL_BLK
./scripts/config --enable CONFIG_BLK_DEV_ZONED
./scripts/config --enable CONFIG_F2FS_FS
./scripts/config --enable CONFIG_KASAN
./scripts/config --enable CONFIG_PROVE_LOCKING
./scripts/config --enable CONFIG_DEBUG_KERNEL
./scripts/config --enable CONFIG_LOCK_DEBUGGING_SUPPORT
./scripts/config --enable CONFIG_DEBUG_FS
./scripts/config --enable CONFIG_BLK_DEBUG_FS
./scripts/config --enable CONFIG_TARGET_DEBUG_FS
./scripts/config --enable CONFIG_NVME_TARGET_DEBUGFS
./scripts/config --enable CONFIG_DEBUG_ATOMIC_SLEEP
./scripts/config --enable CONFIG_FAULT_INJECTION
./scripts/config --enable CONFIG_FAULT_INJECTION_DEBUG_FS
./scripts/config --enable CONFIG_BLK_DEV_NULL_BLK_FAULT_INJECTION
./scripts/config --enable CONFIG_FAIL_MAKE_REQUEST
# Build in CONFIG_IP_NF_IPTABLES for podman
# https://github.com/microsoft/WSL/issues/12108
./scripts/config --enable CONFIG_IP_NF_IPTABLES
#TODO: remove disabling
#Disabling cxl because of compile errors
./scripts/config --disable CONFIG_ACPI_APEI_EINJ_CXL
./scripts/config --disable CONFIG_PCIEAER_CXL
./scripts/config --disable CONFIG_CXL_BUS
./scripts/config --disable CONFIG_CXL_PCI
./scripts/config --disable CONFIG_CXL_ACPI
./scripts/config --disable CONFIG_CXL_PMEM
./scripts/config --disable CONFIG_CXL_MEM
./scripts/config --disable CONFIG_CXL_PORT
./scripts/config --disable CONFIG_CXL_SUSPEND
./scripts/config --disable CONFIG_CXL_REGION
./scripts/config --disable CONFIG_CXL_PMU
./scripts/config --disable CONFIG_DEV_DAX_CXL
yes "" | make olddefconfig

#initramfs creation inspired by https://github.com/floatious/boot-scripts/blob/master/old/boot

# set LOCALVERSION to the empty string, to avoid scripts/setlocalversion from
# appending -dirty or + to the kernel version string. If we do not do this, the
# kernel modules (which uses the kernel version string) might get installed to a
# directory that does not match the kernel version string of the running kernel.
make -j$(nproc) LOCALVERSION=

mkdir -p /tmp/initramfs
cd /tmp/initramfs
gzip -dc /base-initramfs.cpio.gz | cpio -id
#Replace kernel modules
rm -rf lib/modules/*
cd /linux
make -j$(nproc) -s modules_install INSTALL_MOD_PATH=/tmp/initramfs INSTALL_MOD_STRIP=1 LOCALVERSION=
cd /tmp/initramfs
find . | cpio -o -H newc | gzip -c > /initramfs.cpio.gz

cd /linux
mkdir -p /version
if [ -z "$KERNEL_TAG_OVERWRITE" ]; then
  echo "KERNEL_VERSION=$(git describe --always --match=NeVeRmAtCh --abbrev=12 --dirty)" > /version/tag;
else
  echo "KERNEL_VERSION=$KERNEL_TAG_OVERWRITE" > /version/tag;
fi
source /version/tag


cp arch/x86_64/boot/bzImage /output/bzImage-${KERNEL_VERSION}
chmod 755 /output/bzImage-${KERNEL_VERSION}

cp /initramfs.cpio.gz /output/initramfs-${KERNEL_VERSION}.img
chmod 644 /output/initramfs-${KERNEL_VERSION}.img

cp /linux/.config /output/config-${KERNEL_VERSION}

#Pack the modules in a isofs so we can easily mount it in the VM via the same container disk
cd /tmp/initramfs/usr/lib/modules/
echo "$KERNEL_REF" > kernel-ref.info
echo "$KERNEL_VERSION" > kernel-version.info
tar -czvf /tmp/kernel-modules.tar.gz .
mkisofs -o /output/kernel-modules.isofs /tmp/kernel-modules.tar.gz
chmod 644 /output/kernel-modules.isofs
