#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -e
set -x

BUILD_ROOT="${BUILD_ROOT:-}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
linux_dir="${BUILD_ROOT}/linux"
initramfs_dir="${BUILD_ROOT}/tmp/initramfs"
base_initramfs="${BUILD_ROOT}/base-initramfs.cpio.gz"
kernel_config="${BUILD_ROOT}/base-kernel-config"
output_dir="${BUILD_ROOT}/output"
version_dir="${BUILD_ROOT}/version"
initramfs_archive="${BUILD_ROOT}/tmp/initramfs.cpio.gz"
modules_tarball="${BUILD_ROOT}/tmp/kernel-modules.tar.gz"

cd "${BUILD_ROOT:-/}"
mkdir -p "$linux_dir"
cd "$linux_dir"
git init
git remote add origin $KERNEL_TREE
git fetch origin --depth=5 "${KERNEL_REF}"
git checkout FETCH_HEAD
git log -1

cp "$kernel_config" "$linux_dir/.config"
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
./scripts/config --set-val CONFIG_LOCKDEP_BITS 21
./scripts/config --set-val CONFIG_LOCKDEP_CHAINS_BITS 21
./scripts/config --set-val CONFIG_LOCKDEP_STACK_TRACE_BITS 21
# Enable nftables backend for iptables-nft (used by container runtimes).
# Since kernel 7.0-rc, legacy iptables tables (nat, filter) require
# CONFIG_NETFILTER_XTABLES_LEGACY which is not enabled by default.
# Instead of enabling the legacy path, use iptables-nft which translates
# iptables commands to nftables in the kernel via NFT_COMPAT.
./scripts/config --enable CONFIG_NF_TABLES
./scripts/config --enable CONFIG_NF_TABLES_INET
./scripts/config --enable CONFIG_NFT_NAT
./scripts/config --enable CONFIG_NFT_MASQ
./scripts/config --enable CONFIG_NFT_COMPAT
./scripts/config --enable CONFIG_NF_CONNTRACK
./scripts/config --enable CONFIG_NF_NAT
./scripts/config --enable CONFIG_NETFILTER_XTABLES
./scripts/config --enable CONFIG_IP_NF_IPTABLES
./scripts/config --enable CONFIG_IP_NF_NAT
./scripts/config --enable CONFIG_BINFMT_MISC
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

# Drop hardware classes unused by storage-test VMs; retain virtual displays.
./scripts/config --disable CONFIG_DRM_AMDGPU
./scripts/config --disable CONFIG_DRM_I915
./scripts/config --disable CONFIG_DRM_XE
./scripts/config --disable CONFIG_DRM_NOUVEAU
./scripts/config --disable CONFIG_DRM_RADEON
./scripts/config --disable CONFIG_DRM_AMD_DC
./scripts/config --disable CONFIG_DRM_GMA500
./scripts/config --disable CONFIG_DRM_AST
./scripts/config --disable CONFIG_DRM_QXL
# Wireless.
./scripts/config --disable CONFIG_WLAN
./scripts/config --disable CONFIG_MAC80211
./scripts/config --disable CONFIG_CFG80211
./scripts/config --disable CONFIG_RFKILL
# Sound.
./scripts/config --disable CONFIG_SOUND
./scripts/config --disable CONFIG_SND

yes "" | make olddefconfig

# Fail before publishing a kernel that cannot boot the test VM.
required_configs="
CONFIG_VIRTIO
CONFIG_VIRTIO_PCI
CONFIG_VIRTIO_BLK
CONFIG_VIRTIO_NET
CONFIG_VIRTIO_FS
CONFIG_FUSE_FS
CONFIG_BTRFS_FS
CONFIG_ISO9660_FS
CONFIG_BLK_DEV_NULL_BLK
CONFIG_BLK_DEV_ZONED
CONFIG_IKCONFIG_PROC
CONFIG_KASAN
CONFIG_PROVE_LOCKING
"
missing_configs=""
for sym in $required_configs; do
    grep -qE "^${sym}=(y|m)\$" .config || missing_configs="${missing_configs} ${sym}"
done
if [ -n "$missing_configs" ]; then
    echo "error: required kernel options are not enabled after config trim:${missing_configs}" >&2
    exit 1
fi

#initramfs creation inspired by https://github.com/floatious/boot-scripts/blob/master/old/boot

# set LOCALVERSION to the empty string, to avoid scripts/setlocalversion from
# appending -dirty or + to the kernel version string. If we do not do this, the
# kernel modules (which uses the kernel version string) might get installed to a
# directory that does not match the kernel version string of the running kernel.
make -j"$MAKE_JOBS" LOCALVERSION=

mkdir -p "$initramfs_dir" "$version_dir" "$output_dir"
# shellcheck disable=SC2016
initramfs_script='
set -e
initramfs_dir=$1
base_initramfs=$2
linux_dir=$3
make_jobs=$4
initramfs_archive=$5

cd "$initramfs_dir"
lsinitrd --unpack "$base_initramfs"
rm -rf lib/modules/*
cd "$linux_dir"
make -j"$make_jobs" -s modules_install INSTALL_MOD_PATH="$initramfs_dir" INSTALL_MOD_STRIP=1 LOCALVERSION=
cd "$initramfs_dir"
find . | cpio -o -H newc | gzip -c > "$initramfs_archive"
'
if [ "$(id -u)" -eq 0 ]; then
  bash -c "$initramfs_script" -- "$initramfs_dir" "$base_initramfs" \
    "$linux_dir" "$MAKE_JOBS" "$initramfs_archive"
else
  fakeroot -- bash -c "$initramfs_script" -- "$initramfs_dir" \
    "$base_initramfs" "$linux_dir" "$MAKE_JOBS" "$initramfs_archive"
fi

cd "$linux_dir"
if [ -z "$KERNEL_TAG_OVERWRITE" ]; then
  echo "KERNEL_VERSION=$(git describe --always --match=NeVeRmAtCh --abbrev=12 --dirty)" > "$version_dir/tag";
else
  echo "KERNEL_VERSION=$KERNEL_TAG_OVERWRITE" > "$version_dir/tag";
fi
# shellcheck disable=SC1091
source "$version_dir/tag"


cp vmlinux "$output_dir/vmlinux-${KERNEL_VERSION}"
chmod 755 "$output_dir/vmlinux-${KERNEL_VERSION}"

cp "$initramfs_archive" "$output_dir/initramfs-${KERNEL_VERSION}.img"
chmod 644 "$output_dir/initramfs-${KERNEL_VERSION}.img"

cp "$linux_dir/.config" "$output_dir/config-${KERNEL_VERSION}"

#Pack the modules in a isofs so we can easily mount it in the VM via the same container disk
cd "$initramfs_dir/usr/lib/modules/"
echo "$KERNEL_REF" > kernel-ref.info
echo "$KERNEL_VERSION" > kernel-version.info
tar --owner=0 --group=0 --numeric-owner -czvf "$modules_tarball" .
mkisofs -o "$output_dir/kernel-modules.isofs" "$modules_tarball"
chmod 644 "$output_dir/kernel-modules.isofs"
