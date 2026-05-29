#!/usr/bin/env bash
#
# ecu150v2_flash_rauc_ab.sh
#
# Build a RAUC A/B layout on an SD card or eMMC for the ecu150v2.
#
# Layout (matches meta-ecu150v2's RAUC system.conf):
#   0 .. 32 KiB     reserved
#   32 KiB          imx-boot.tagged (raw, no partition entry)
#   8 MiB ..        part1: ext4, label "rootfs.0" -> slot A (populated)
#                   part2: ext4, label "rootfs.1" -> slot B (empty, filled by first OTA)
#                   part3: ext4, label "data"     -> persistent /data
#
# Kernel and dtb live inside each rootfs (/boot), so there is NO FAT boot
# partition. U-Boot loads them from the active ext4 rootfs.
#
# The script does NOT touch the U-Boot environment. On first boot, U-Boot
# uses its compiled-in defaults (BOOT_ORDER="A B", BOOT_A_LEFT=3, BOOT_B_LEFT=3).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR_DEFAULT="${SCRIPT_DIR}/../../yocto_src/bld-wayland/tmp/deploy/images/ecu150v2"

# Partition geometry (MiB). p1 and p2 must be equal (RAUC slot symmetry).
ROOTFS_OFFSET_MIB=8
ROOTFS_SIZE_MIB_DEFAULT=4096    # 4 GiB per slot; tune with --rootfs-size
# /data takes the remaining space (100%).

usage() {
    cat <<EOF
Usage: sudo $(basename "$0") --device /dev/sdX [options]

Partition an SD card or eMMC for RAUC A/B and populate slot A.

Options:
  -d, --device DEV          Target whole-disk block device
                            (e.g. /dev/sdb for SD, /dev/mmcblk0 for eMMC).
      --deploy-dir DIR      Yocto deploy/images/ecu150v2 directory.
                            Default: ${DEPLOY_DIR_DEFAULT}
      --rootfs-size MIB     Size of each rootfs slot in MiB.
                            Default: ${ROOTFS_SIZE_MIB_DEFAULT}
      --populate-b          Also populate slot B with the same rootfs
                            (useful for bench testing rollback).
  -y, --yes                 Skip the confirmation prompt
  -h, --help                Show this help
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

device=""
deploy_dir="${DEPLOY_DIR_DEFAULT}"
rootfs_size_mib="${ROOTFS_SIZE_MIB_DEFAULT}"
populate_b="false"
assume_yes="false"

while (( $# )); do
    case "$1" in
        -d|--device)     device="${2:-}";          shift 2 ;;
        --deploy-dir)    deploy_dir="${2:-}";      shift 2 ;;
        --rootfs-size)   rootfs_size_mib="${2:-}"; shift 2 ;;
        --populate-b)    populate_b="true";        shift ;;
        -y|--yes)        assume_yes="true";        shift ;;
        -h|--help)       usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${device}" ]] || { usage; exit 2; }
[[ ${EUID} -eq 0 ]] || die "Must be run as root (use sudo)"
[[ -b "${device}" ]] || die "Not a block device: ${device}"
[[ -d "${deploy_dir}" ]] || die "Deploy dir not found: ${deploy_dir}"
[[ "${rootfs_size_mib}" =~ ^[0-9]+$ ]] || die "--rootfs-size must be an integer (MiB)"

imx_boot="${deploy_dir}/imx-boot.tagged"
rootfs_archive="${deploy_dir}/imx-image-core-ecu150v2.rootfs.tar.zst"

[[ -f "${imx_boot}" ]]       || die "Missing: ${imx_boot}"
[[ -f "${rootfs_archive}" ]] || die "Missing: ${rootfs_archive}"

echo "Target device  : ${device}"
lsblk -dno NAME,SIZE,MODEL,TRAN "${device}" || true
echo "Deploy dir     : ${deploy_dir}"
echo "Rootfs size    : ${rootfs_size_mib} MiB per slot"
echo "Populate slotB : ${populate_b}"
echo

if [[ "${assume_yes}" != "true" ]]; then
    read -r -p 'This will ERASE the device. Type YES to continue: ' answer
    [[ "${answer}" == "YES" ]] || die "Aborted"
fi

# Resolve partition node names: /dev/sdb       -> /dev/sdb1
#                               /dev/mmcblk0   -> /dev/mmcblk0p1
case "${device}" in
    *mmcblk[0-9]|*nvme[0-9]n[0-9]|*loop[0-9]) part_prefix="${device}p" ;;
    *) part_prefix="${device}" ;;
esac
slot_a_part="${part_prefix}1"
slot_b_part="${part_prefix}2"
data_part="${part_prefix}3"

# Unmount any partitions still mounted on this device.
while read -r part; do
    [[ -n "${part}" ]] || continue
    if findmnt -rn -S "${part}" >/dev/null; then
        umount "${part}"
    fi
done < <(lsblk -lnpo NAME "${device}" | tail -n +2)

# Wipe and partition.
wipefs -a -f "${device}" >/dev/null
dd if=/dev/zero of="${device}" bs=1M count=8 conv=fsync status=none

slot_a_end_mib=$(( ROOTFS_OFFSET_MIB + rootfs_size_mib ))
slot_b_end_mib=$(( slot_a_end_mib + rootfs_size_mib ))

parted -s "${device}" mklabel msdos
parted -s "${device}" unit MiB mkpart primary ext4 "${ROOTFS_OFFSET_MIB}" "${slot_a_end_mib}"
parted -s "${device}" unit MiB mkpart primary ext4 "${slot_a_end_mib}"  "${slot_b_end_mib}"
parted -s "${device}" unit MiB mkpart primary ext4 "${slot_b_end_mib}"  100%

partprobe "${device}"
udevadm settle

[[ -b "${slot_a_part}" ]] || die "Slot A partition not present: ${slot_a_part}"
[[ -b "${slot_b_part}" ]] || die "Slot B partition not present: ${slot_b_part}"
[[ -b "${data_part}"   ]] || die "Data partition not present: ${data_part}"

# Write imx-boot.tagged at 32 KiB (matches IMX_BOOT_SEEK).
dd if="${imx_boot}" of="${device}" bs=1K seek=32 conv=fsync status=progress

# Filesystem labels are cosmetic (for lsblk/debugging only) — RAUC
# system.conf and the /data mount both reference device paths directly.
# Labels are kept aligned with RAUC slot names for visual clarity.
mkfs.ext4 -F -L rootfs.0 "${slot_a_part}"
mkfs.ext4 -F -L rootfs.1 "${slot_b_part}"
mkfs.ext4 -F -L data     "${data_part}"

# Populate slot A (and optionally slot B).
mnt=$(mktemp -d)
trap 'umount "${mnt}" 2>/dev/null || true; rmdir "${mnt}" 2>/dev/null || true' EXIT

extract_rootfs() {
    local target="$1"
    mount "${target}" "${mnt}"
    zstdcat "${rootfs_archive}" \
        | tar --numeric-owner --xattrs --xattrs-include='*' -xpf - -C "${mnt}"

    # Sanity check: U-Boot's RAUC C policy hard-codes these paths
    # (RAUC_KERNEL_PATH / RAUC_FDT_PATH). If either is missing the
    # board will fail to boot from this slot, so fail the flash early
    # rather than discovering it on the target serial console.
    local kernel_path="${mnt}/boot/Image"
    local dtb_path="${mnt}/boot/imx8mp-evk.dtb"
    if [[ ! -e "${kernel_path}" ]]; then
        umount "${mnt}" || true
        die "Rootfs missing ${kernel_path#${mnt}} (kernel-image not installed?)"
    fi
    if [[ ! -e "${dtb_path}" ]]; then
        umount "${mnt}" || true
        die "Rootfs missing ${dtb_path#${mnt}} (kernel-devicetree not in IMAGE_INSTALL?)"
    fi
    echo "  ok: $(ls -lL "${kernel_path}" "${dtb_path}" | awk '{print $NF, $5}')"

    sync
    umount "${mnt}"
}

echo "Populating slot A (${slot_a_part}) ..."
extract_rootfs "${slot_a_part}"

if [[ "${populate_b}" == "true" ]]; then
    echo "Populating slot B (${slot_b_part}) ..."
    extract_rootfs "${slot_b_part}"
else
    echo "Slot B (${slot_b_part}) left empty; first 'rauc install' will fill it."
fi

# Copy the RAUC bundle to /data so it is immediately available for OTA on first boot.
# Prefer the canonical symlink name; fall back to any .raucb in the deploy dir.
bundle_src=""
if [[ -f "${deploy_dir}/update-bundle-ecu150v2.raucb" ]]; then
    bundle_src="$(realpath "${deploy_dir}/update-bundle-ecu150v2.raucb")"
else
    bundle_src="$(find "${deploy_dir}" -maxdepth 1 -name "*.raucb" | sort | tail -1)"
fi

if [[ -n "${bundle_src}" && -f "${bundle_src}" ]]; then
    echo "Copying bundle to /data: $(basename "${bundle_src}") ..."
    mount "${data_part}" "${mnt}"
    cp "${bundle_src}" "${mnt}/"
    sync
    umount "${mnt}"
    echo "  ok: bundle copied."
else
    echo "WARNING: No .raucb bundle found in ${deploy_dir} — /data left empty." >&2
    echo "         Copy a bundle manually before running 'rauc install'." >&2
fi

sync

echo
echo "Done. Resulting layout:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "${device}"
echo
echo "Next steps:"
echo "  1. Boot the target from ${device}."
echo "  2. On the target: 'rauc status' should show booted=rootfs.0, slot B empty."
echo "  3. Push an OTA bundle:"
echo "       scp update-bundle-ecu150v2.raucb root@<target>:/tmp/"
echo "       ssh root@<target> rauc install /tmp/update-bundle-ecu150v2.raucb"
