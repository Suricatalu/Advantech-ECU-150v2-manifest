#!/usr/bin/env bash
#
# ecu150v2_flash_ubuntu_overlay.sh — flash an SD/eMMC card for the
# Advantech ECU-150v2 (NXP i.MX8M Plus / imx8mp). Supports a plain non-RAUC
# single-rootfs layout (default) and a RAUC A/B layout (--rauc).
#
# Target board: imx8mp (ecu150v2). The script writes the i.MX bootloader at a
# raw offset, then creates the rootfs partition(s) and optionally a trailing
# ext4 partition for the overlayfs upper/work dirs (kernel cmdline
# overlayrwdev=/dev/mmcblkXpN).
#
# Partition layouts (NO separate boot partition; p1 starts at the rootfs):
#
#   non-RAUC (default):
#     p1  ext4  rootfs              (/boot/Image + /boot/*.dtb live here)
#     p2  ext4  overlay rwdata      (optional, --overlay-data; else tmpfs)
#
#   RAUC (--rauc):
#     p1  ext4  rootfs A            (populated by this script)
#     p2  ext4  rootfs B            (left empty; filled later by 'rauc install')
#     p3  ext4  /data               (RAUC status + persistent data, A/B shared)
#     p4  ext4  overlay rwdata      (optional, --overlay-data; else tmpfs)
#
#   imx-boot is always written raw at 32 KiB, before p1 (no boot partition).
#
# Rootfs sources:
#   --yocto/--bsp  Yocto rootfs tarball (REQUIRED: source of kernel modules /
#                  firmware; also the rootfs base when --ubuntu is omitted)
#   --ubuntu       External Ubuntu rootfs tarball (OPTIONAL base). When given,
#                  kernel modules + firmware are copied from the Yocto tarball
#                  on top of it (kernel Image + DTB come from --kernel/--dtb).
#
# Boot artifacts (looked up by bare name inside --images, or by explicit path):
#   --kernel       kernel Image  -> installed as /boot/Image (renamed if needed)
#   --dtb          DTB file      -> /boot/<name> + /boot/imx8mp-evk.dtb
#   --imx-boot     imx-boot      -> written raw at 32 KiB
#
# Kernel selection:
#   --kernel <file>   explicit path or bare name (always wins). Point this at
#                     Image-initramfs-ecu150v2.bin to use the overlay-capable
#                     initramfs kernel; the script copies it verbatim and does
#                     NOT care whether the image embeds a cpio.
#   otherwise         auto-detect Image-ecu150v2.bin in --images
#   final fallback    whatever /boot/Image the rootfs tarball already ships
#
# DTB selection priority:
#   1. --dtb <file>   explicit path or bare name inside --images
#   2. auto-detect    imx8mp-evk-ecu150v2.dtb in --images
#   3. fallback       whatever /boot/*.dtb the rootfs tarball ships
#
# Overlay data partition (--overlay-data):
#   Adds a 2nd ext4 partition (label "rwdata") after the rootfs to persist the
#   overlayfs upper/work dirs. Pair with an overlay-capable kernel + bootargs
#   overlayrwdev=/dev/mmcblkXp2.
#
# NOTE: the ECU-150v2 BSP U-Boot already relocates the FDT to 0x48000000 so a
# 45 MB Image-initramfs no longer overwrites the device tree; no manual
# setenv is needed with the current bootloader.
#
# Examples:
#   # DEFAULT: non-RAUC plain kernel, single rootfs (no overlay):
#   sudo ./ecu150v2_flash_ubuntu_overlay.sh -d /dev/sdX -i ~/deploy \
#       --yocto imx-image-core-ecu150v2.rootfs.tar.zst
#
#   # non-RAUC overlay: initramfs kernel + trailing rwdata partition (p2):
#   sudo ./ecu150v2_flash_ubuntu_overlay.sh -d /dev/sdX -i ~/deploy --overlay-data \
#       --kernel Image-initramfs-ecu150v2.bin \
#       --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
#
#   # RAUC A/B + /data, plus overlay rwdata on p4:
#   sudo ./ecu150v2_flash_ubuntu_overlay.sh -d /dev/sdX -i ~/deploy --rauc --overlay-data \
#       --kernel Image-initramfs-ecu150v2.bin \
#       --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
#
#   # External Ubuntu base + Yocto modules/firmware (plain kernel):
#   sudo ./ecu150v2_flash_ubuntu_overlay.sh -d /dev/sdX -i ~/deploy \
#       --ubuntu ubuntu-24.04-arm64-generic.rootfs.tar.zst \
#       --yocto  imx-image-core-ecu150v2.rootfs.tar.zst

set -Eeuo pipefail

PROG="${0##*/}"

# ----------------------------------------------------------------------------
# Tunables (override via flags; sane i.MX8MP SD/eMMC defaults)
# ----------------------------------------------------------------------------
IMX_BOOT_OFFSET_KB=32       # i.MX8MP writes imx-boot at 32 KiB on SD/eMMC user area
PART_START="8MiB"           # rootfs partition starts after the bootloader gap
WIPE_MIB=16                 # zero the first N MiB to clear old tables/bootloader
KERNEL_IMAGE=""             # explicit kernel image; auto-detected when empty
DTB_FILE=""                 # explicit DTB file; auto-detected when empty
RAUC=0                     # 1 = RAUC A/B layout (p1 A, p2 B, p3 /data, p4 overlay)
OVERLAY_DATA=0             # 1 = add an ext4 partition for overlay upper/work (last part)
ROOTFS_SIZE="6GiB"         # size of EACH rootfs partition (non-RAUC p1; RAUC each A/B slot)
DATA_SIZE="1GiB"           # RAUC /data partition size (p3)
RWDATA_LABEL="rwdata"      # filesystem label of the overlay data partition

# ----------------------------------------------------------------------------
# Small helpers (same palette/style as adv_chroot.sh)
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$PROG" "$*" >&2; }
ok()   { printf '\033[1;32m[%s]\033[0m %s\n' "$PROG" "$*" >&2; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$PROG" "$*" >&2; }
err()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$PROG" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat >&2 <<'EOF'
Usage: ecu150v2_flash_ubuntu_overlay.sh -d <disk> --yocto <tarball> [options]

Target: Advantech ECU-150v2 (NXP i.MX8MP / imx8mp). Default non-RAUC; --rauc for A/B.

Required:
  -d, --disk <dev>        target block device (e.g. /dev/sdb)
  --yocto, --bsp <file>   Yocto rootfs tarball (modules/firmware; base if no --ubuntu)

Optional:
  -i, --images <dir>      folder to resolve bare artifact names (default: .)
  --ubuntu <file>         external Ubuntu rootfs tarball (base; Yocto overlaid on top)
  -k, --kernel <file>     kernel Image -> /boot/Image (auto: Image-ecu150v2.bin;
                          point at Image-initramfs-ecu150v2.bin for overlay boot)
  -D, --dtb <file>        DTB -> /boot (auto: imx8mp-evk-ecu150v2.dtb)
  -B, --imx-boot <file>   imx-boot bootloader (default: imx-boot)
  -R, --rauc              RAUC A/B layout (p1 rootfsA, p2 rootfsB, p3 /data, [p4 overlay])
  -O, --overlay-data      add an ext4 partition for overlay upper/work (last partition)
  --rootfs-size <sz>      size of each rootfs partition (default: 6GiB)
  --data-size <sz>        RAUC /data partition size (default: 1GiB; --rauc only)
  --offset <kb>           imx-boot raw offset in KiB (default: 32)
  --part-start <sz>       first partition start (default: 8MiB)
  -y, --yes               do not prompt for confirmation
  -h, --help              show this help

Partition design (NO separate boot partition; imx-boot is raw at 32 KiB,
p1 starts directly at the rootfs):

  non-RAUC (default):
    p1  rootfs                         (/boot/Image + /boot/*.dtb)
    p2  overlay rwdata                 (only with --overlay-data; else tmpfs)

  RAUC (--rauc):
    p1  rootfs A                       (flashed now)
    p2  rootfs B                       (empty; populated by 'rauc install')
    p3  /data                          (RAUC status records + shared data)
    p4  overlay rwdata                 (only with --overlay-data; else tmpfs)
EOF
    exit "${1:-0}"
}

# Re-exec through sudo if we are not root (partitioning/dd/mount need it).
ORIG_ARGS=()
ensure_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log "elevating privileges via sudo ..."
        exec sudo -E -- "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
}

# Pick the right decompressor for a tarball by extension, then run tar.
#   tar_xf <tarball> <tar-args...>
tar_xf() {
    local tb="$1"; shift
    local dc=()
    case "$tb" in
        *.zst|*.tzst) command -v unzstd >/dev/null || die "zstd not installed (need unzstd for $tb)"; dc=(--use-compress-program=unzstd) ;;
        *.xz)         dc=(-J) ;;
        *.gz|*.tgz)   dc=(-z) ;;
        *.bz2|*.tbz2) dc=(-j) ;;
        *.tar)        dc=() ;;
        *) warn "unknown tar extension for $tb; letting tar autodetect" ;;
    esac
    tar "${dc[@]}" -f "$tb" "$@"
}

# Resolve a file argument: accept an absolute/relative path, or a bare name
# living inside the --images folder. Echoes an absolute path (or the input
# unchanged so the caller can produce a clear error).
resolve_artifact() {
    local f="$1"
    [[ -n "$f" ]] || { printf '%s' ""; return; }
    if [[ -e "$f" ]]; then readlink -f "$f"; return; fi
    if [[ -e "$IMAGES/$f" ]]; then readlink -f "$IMAGES/$f"; return; fi
    printf '%s' "$f"
}

# Convert a size string (e.g. 8MiB, 6GiB, 512M, 2G, or a bare number = MiB)
# into an integer number of MiB. Used to compute partition offsets.
to_mib() {
    local v="$1"
    if   [[ "$v" =~ ^([0-9]+)[[:space:]]*[Gg]i?[Bb]?$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
    elif [[ "$v" =~ ^([0-9]+)[[:space:]]*[Mm]i?[Bb]?$ ]]; then echo "${BASH_REMATCH[1]}"
    elif [[ "$v" =~ ^([0-9]+)$ ]];                        then echo "${BASH_REMATCH[1]}"
    else die "cannot parse size '$v' (use e.g. 6GiB, 512MiB)"
    fi
}

# ----------------------------------------------------------------------------
# Disk selection (fzf if available, else manual) — only when -d is omitted
# ----------------------------------------------------------------------------
list_disks() {
    lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -E '(usb|mmc)' \
        || lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN
}

select_disk() {
    echo "" >&2
    log "available disks:" >&2
    list_disks >&2
    echo "" >&2
    local disk=""
    if command -v fzf >/dev/null 2>&1; then
        disk=$(list_disks | fzf --prompt="Select target disk: " --height=12 | awk '{print $1}')
    else
        read -rp "Enter target disk (e.g. /dev/sdb): " disk
    fi
    printf '%s' "$disk"
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
WORKDIR=""
cleanup() {
    local rc=$?
    [[ -n "$WORKDIR" ]] || return $rc
    # Unmount anything we mounted under the workdir, deepest first.
    local m
    for m in $(awk -v r="$WORKDIR/" '$2 ~ "^"r {print $2}' /proc/self/mounts | sort -r); do
        umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done
    if [[ $rc -eq 0 ]]; then
        rm -rf "$WORKDIR"
    else
        warn "left working dir for inspection: $WORKDIR"
    fi
    return $rc
}

# ----------------------------------------------------------------------------
# Core steps
# ----------------------------------------------------------------------------
# Partition the disk. No separate boot partition: imx-boot is raw at 32 KiB, so
# p1 starts directly at the rootfs (default PART_START = 8 MiB).
#   non-RAUC: p1 rootfs [, p2 overlay rwdata]
#   RAUC:     p1 rootfs A, p2 rootfs B, p3 /data [, p4 overlay rwdata]
partition_disk() {
    local disk="$1"

    log "unmounting any existing partitions on $disk"
    umount "${disk}"* 2>/dev/null || true

    log "wiping first ${WIPE_MIB} MiB of $disk"
    dd if=/dev/zero of="$disk" bs=1M count="$WIPE_MIB" conv=fsync status=none
    sync

    local start rootfs_mib data_mib e1 e2 e3
    start="$(to_mib "$PART_START")"
    rootfs_mib="$(to_mib "$ROOTFS_SIZE")"
    data_mib="$(to_mib "$DATA_SIZE")"

    parted -s "$disk" mklabel msdos

    if [[ $RAUC -eq 1 ]]; then
        e1=$(( start + rootfs_mib ))     # end of rootfs A
        e2=$(( e1 + rootfs_mib ))        # end of rootfs B
        e3=$(( e2 + data_mib ))          # end of /data
        log "RAUC layout: p1 rootfsA (${ROOTFS_SIZE}), p2 rootfsB (${ROOTFS_SIZE}), p3 /data (${DATA_SIZE})$([[ $OVERLAY_DATA -eq 1 ]] && echo ', p4 overlay (rest)')"
        parted -s "$disk" mkpart primary ext4 "${start}MiB" "${e1}MiB"   # rootfs A
        parted -s "$disk" mkpart primary ext4 "${e1}MiB"    "${e2}MiB"   # rootfs B
        if [[ $OVERLAY_DATA -eq 1 ]]; then
            parted -s "$disk" mkpart primary ext4 "${e2}MiB" "${e3}MiB"  # /data
            parted -s "$disk" mkpart primary ext4 "${e3}MiB" 100%        # overlay rwdata
        else
            parted -s "$disk" mkpart primary ext4 "${e2}MiB" 100%        # /data (rest)
        fi
    else
        if [[ $OVERLAY_DATA -eq 1 ]]; then
            e1=$(( start + rootfs_mib ))
            log "non-RAUC layout: p1 rootfs (${ROOTFS_SIZE}), p2 overlay rwdata (rest)"
            parted -s "$disk" mkpart primary ext4 "${start}MiB" "${e1}MiB"
            parted -s "$disk" mkpart primary ext4 "${e1}MiB"    100%
        else
            log "non-RAUC layout: single rootfs partition (start ${PART_START})"
            parted -s "$disk" mkpart primary ext4 "${start}MiB" 100%
        fi
    fi
    parted -s "$disk" set 1 boot on

    # Let the kernel re-read the new table before mkfs.
    sync
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 1

    if [[ $RAUC -eq 1 ]]; then
        log "formatting rootfs A ${disk}${P}1 (ext4, label rootfs_a)"
        mkfs.ext4 -F -L rootfs_a "${disk}${P}1"
        log "formatting rootfs B ${disk}${P}2 (ext4, label rootfs_b)"
        mkfs.ext4 -F -L rootfs_b "${disk}${P}2"
        log "formatting /data ${disk}${P}3 (ext4, label data)"
        mkfs.ext4 -F -L data "${disk}${P}3"
        if [[ $OVERLAY_DATA -eq 1 ]]; then
            log "formatting overlay rwdata ${disk}${P}4 (ext4, label ${RWDATA_LABEL})"
            mkfs.ext4 -F -L "$RWDATA_LABEL" "${disk}${P}4"
        fi
    else
        log "formatting rootfs partition ${disk}${P}1 (ext4)"
        mkfs.ext4 -F -L rootfs "${disk}${P}1"
        if [[ $OVERLAY_DATA -eq 1 ]]; then
            log "formatting overlay rwdata partition ${disk}${P}2 (ext4, label ${RWDATA_LABEL})"
            mkfs.ext4 -F -L "$RWDATA_LABEL" "${disk}${P}2"
        fi
    fi
}

# Populate the rootfs partition. Two modes:
#   - UBUNTU set  : external Ubuntu base + Yocto kernel modules/firmware on top
#   - UBUNTU empty: the Yocto rootfs tarball is the whole base
# Kernel Image + DTB are always (re)installed afterwards from KERNEL_IMAGE/DTB_FILE.
populate_rootfs() {
    local mnt="$1"

    if [[ -n "$UBUNTU" ]]; then
        log "extracting external Ubuntu rootfs: ${UBUNTU##*/}  (may take a while)"
        tar_xf "$UBUNTU" --numeric-owner -x -C "$mnt"

        log "extracting Yocto modules/firmware/boot from: ${BSP##*/}"
        local bsp="$WORKDIR/bsp"
        mkdir -p "$bsp"
        # Cover merged-usr (./usr/lib/...) and classic (./lib/...) layouts, plus /boot.
        tar_xf "$BSP" --numeric-owner -x -C "$bsp" --wildcards \
            '*/lib/modules/*' '*/lib/firmware/*' '*/boot/*' \
            'lib/modules/*' 'lib/firmware/*' 'boot/*' 2>/dev/null || true

        # Locate where things actually landed.
        local mods fwdir bootdir bsproot
        mods=$(find "$bsp" -type d -path '*/lib/modules' | head -1)
        [[ -n "$mods" ]] || die "no kernel modules found in Yocto tarball ($BSP)"
        bsproot="${mods%/lib/modules}"
        fwdir="$bsproot/lib/firmware"
        bootdir=$(find "$bsp" -type d -name boot | head -1)

        log "overlaying kernel modules -> /usr/lib/modules"
        install -d "$mnt/usr/lib/modules"
        cp -a "$mods/." "$mnt/usr/lib/modules/"
        KVER=$(ls "$mods" | head -1)
        log "kernel version (KVER): $KVER"

        # Check kernel-devsrc tree (required for on-target source builds).
        if [[ -d "$mnt/usr/lib/modules/$KVER/build" ]]; then
            log "kernel-devsrc tree found ($KVER/build) — creating /usr/src/kernel symlink"
            install -d "$mnt/usr/src"
            ln -sfn "/usr/lib/modules/$KVER/source" "$mnt/usr/src/kernel"
        else
            warn "kernel-devsrc tree missing: usr/lib/modules/$KVER/build/ not in Yocto tarball"
            warn "  on-target out-of-tree module builds will fail (add kernel-devsrc to IMAGE_INSTALL)"
        fi

        if [[ -d "$fwdir" ]]; then
            log "overlaying firmware -> /usr/lib/firmware"
            install -d "$mnt/usr/lib/firmware"
            cp -a "$fwdir/." "$mnt/usr/lib/firmware/"
        else
            warn "no firmware dir in Yocto tarball; WiFi/VPU/NPU blobs may be missing"
        fi

        # Provide a /boot baseline (kernel/dtb) so the partition is bootable even
        # when --kernel/--dtb are not given; KERNEL_IMAGE/DTB_FILE override below.
        if [[ -n "$bootdir" && -d "$bootdir" ]]; then
            log "overlaying baseline kernel Image + dtb -> /boot"
            install -d "$mnt/boot"
            cp -aL "$bootdir/." "$mnt/boot/" 2>/dev/null || cp -a "$bootdir/." "$mnt/boot/"
        fi

        # Rebuild module dependency DB against the merged rootfs (host-side).
        log "rebuilding module dependencies (depmod -b)"
        depmod -a -b "$mnt" "$KVER" 2>/dev/null \
            || warn "depmod failed on host; run 'sudo depmod -a' on the target after boot"
    else
        log "no --ubuntu given: using the Yocto rootfs tarball as the base"
        log "extracting Yocto rootfs: ${BSP##*/}  (may take a while)"
        tar_xf "$BSP" --numeric-owner -x -C "$mnt"

        # Detect KVER for the summary; the Yocto tarball already ships depmod data.
        local mods
        mods=$(find "$mnt" -maxdepth 5 -type d -path '*/lib/modules' | head -1)
        if [[ -n "$mods" ]]; then
            KVER=$(ls "$mods" | head -1)
            log "kernel version (KVER): $KVER"
        else
            warn "no /lib/modules found in Yocto rootfs tarball"
        fi
    fi

    # Common: install/override kernel Image and DTB from the deploy folder.
    # Any selected Image is unified to the canonical name /boot/Image.
    if [[ -n "$KERNEL_IMAGE" ]]; then
        log "installing kernel -> /boot/Image: ${KERNEL_IMAGE##*/}"
        install -d "$mnt/boot"
        cp -L "$KERNEL_IMAGE" "$mnt/boot/Image"
    fi

    if [[ -n "$DTB_FILE" ]]; then
        log "installing DTB -> /boot/${DTB_FILE##*/}"
        install -d "$mnt/boot"
        cp -L "$DTB_FILE" "$mnt/boot/${DTB_FILE##*/}"
        # Also place it under the canonical name U-Boot expects (imx8mp-evk.dtb).
        local dtb_canonical="imx8mp-evk.dtb"
        if [[ "${DTB_FILE##*/}" != "$dtb_canonical" ]]; then
            cp -L "$DTB_FILE" "$mnt/boot/$dtb_canonical"
            log "  also installed as /boot/$dtb_canonical"
        fi
    fi
}

write_bootloader() {
    local disk="$1"
    log "writing imx-boot to ${disk} @ ${IMX_BOOT_OFFSET_KB} KiB (${IMX_BOOT##*/})"
    # conv=notrunc keeps the rest of the disk intact; fsync flushes before return.
    dd if="$IMX_BOOT" of="$disk" bs=1k seek="$IMX_BOOT_OFFSET_KB" \
        conv=fsync,notrunc status=none
    sync
}

# ----------------------------------------------------------------------------
# Argument parsing / main
# ----------------------------------------------------------------------------
DISK=""
IMAGES="."
UBUNTU=""
BSP=""
IMX_BOOT="imx-boot"
ASSUME_YES=0
KVER=""

main() {
    ORIG_ARGS=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--disk|--device) DISK="${2:-}"; shift 2 ;;
            -i|--images)        IMAGES="${2:-}"; shift 2 ;;
            -u|--ubuntu)        UBUNTU="${2:-}"; shift 2 ;;
            -b|--bsp|--yocto)   BSP="${2:-}"; shift 2 ;;
            -B|--imx-boot)      IMX_BOOT="${2:-}"; shift 2 ;;
            -k|--kernel|--image) KERNEL_IMAGE="${2:-}"; shift 2 ;;
            -D|--dtb)           DTB_FILE="${2:-}"; shift 2 ;;
            -R|--rauc)          RAUC=1; shift ;;
            -O|--overlay-data)  OVERLAY_DATA=1; shift ;;
            --rootfs-size)      ROOTFS_SIZE="${2:-}"; shift 2 ;;
            --data-size)        DATA_SIZE="${2:-}"; shift 2 ;;
            --offset)           IMX_BOOT_OFFSET_KB="${2:-}"; shift 2 ;;
            --part-start)       PART_START="${2:-}"; shift 2 ;;
            -y|--yes)           ASSUME_YES=1; shift ;;
            -h|--help)          usage 0 ;;
            *) err "unknown option: $1"; usage 1 ;;
        esac
    done

    ensure_root

    # Resolve the images folder and artifact paths.
    [[ -d "$IMAGES" ]] || die "images folder not found: $IMAGES"
    IMAGES="$(cd "$IMAGES" && pwd -P)"

    [[ -n "$BSP"    ]] || die "missing --yocto/--bsp <Yocto rootfs tarball>"
    BSP="$(resolve_artifact "$BSP")"
    IMX_BOOT="$(resolve_artifact "$IMX_BOOT")"

    [[ -f "$BSP"      ]] || die "Yocto rootfs not found: $BSP"
    [[ -f "$IMX_BOOT" ]] || die "imx-boot not found: $IMX_BOOT (use --imx-boot or put it in --images)"

    # --ubuntu is optional: when omitted, the Yocto rootfs is the base.
    if [[ -n "$UBUNTU" ]]; then
        UBUNTU="$(resolve_artifact "$UBUNTU")"
        [[ -f "$UBUNTU" ]] || die "Ubuntu rootfs not found: $UBUNTU"
    fi

    # Resolve --kernel, or auto-detect the plain kernel. The script treats the
    # image as an opaque blob: to boot overlay-root, point --kernel at
    # Image-initramfs-ecu150v2.bin yourself.
    if [[ -n "$KERNEL_IMAGE" ]]; then
        KERNEL_IMAGE="$(resolve_artifact "$KERNEL_IMAGE")"
        [[ -f "$KERNEL_IMAGE" ]] || die "kernel image not found: $KERNEL_IMAGE"
    else
        local candidate
        candidate="$(resolve_artifact "Image-ecu150v2.bin")"
        if [[ -f "$candidate" ]]; then
            KERNEL_IMAGE="$candidate"
            log "auto-detected kernel: ${KERNEL_IMAGE##*/}"
        else
            warn "Image-ecu150v2.bin not found; /boot/Image will come from the rootfs tarball"
            warn "But the default /boot/Image may support overlay when the OVERLAY_INITRAMFS_ROOT is enabled in bld-wayland/conf/local.conf`"
            warn "  (pass --kernel for an explicit image, e.g. Image-initramfs-ecu150v2.bin)"
        fi
    fi

    # Resolve --dtb, or auto-detect imx8mp-evk-ecu150v2.dtb.
    if [[ -n "$DTB_FILE" ]]; then
        DTB_FILE="$(resolve_artifact "$DTB_FILE")"
        [[ -f "$DTB_FILE" ]] || die "DTB not found: $DTB_FILE"
    else
        local dtb_candidate
        dtb_candidate="$(resolve_artifact "imx8mp-evk-ecu150v2.dtb")"
        if [[ -f "$dtb_candidate" ]]; then
            DTB_FILE="$dtb_candidate"
            log "auto-detected DTB: ${DTB_FILE##*/}"
        else
            warn "imx8mp-evk-ecu150v2.dtb not found in --images folder; DTB will come from BSP tarball"
        fi
    fi

    # Pick a disk if not given, then validate it.
    [[ -n "$DISK" ]] || DISK="$(select_disk)"
    [[ -n "$DISK" ]] || die "no target disk selected"
    [[ -b "$DISK" ]] || die "$DISK is not a block device"

    # Partition node suffix: mmcblk0p1 / nvme0n1p1 vs sdb1.
    if [[ "$DISK" =~ [0-9]$ ]]; then P="p"; else P=""; fi

    # Confirm (destructive!).
    echo "" >&2
    echo "==================================================" >&2
    echo "  ECU-150v2 (i.MX8MP) SD/eMMC flash" >&2
    echo "==================================================" >&2
    printf "  Target disk : %s\n" "$DISK" >&2
    printf "  Layout mode : %s\n" "$([[ $RAUC -eq 1 ]] && echo 'RAUC A/B' || echo 'non-RAUC')" >&2
    printf "  Ubuntu base : %s\n" "${UBUNTU:-(none; using Yocto rootfs)}" >&2
    printf "  Yocto rootfs: %s\n" "$BSP" >&2
    printf "  kernel Image: %s\n" "${KERNEL_IMAGE:-(from rootfs tarball)}" >&2
    printf "  DTB         : %s\n" "${DTB_FILE:-(from rootfs tarball)}" >&2
    printf "  imx-boot    : %s  (@ %s KiB)\n" "$IMX_BOOT" "$IMX_BOOT_OFFSET_KB" >&2
    printf "  part start  : %s\n" "$PART_START" >&2
    if [[ $RAUC -eq 1 ]]; then
        printf "  partitions  : p1 rootfsA (%s), p2 rootfsB (%s), p3 /data (%s)%s\n" \
            "$ROOTFS_SIZE" "$ROOTFS_SIZE" "$DATA_SIZE" \
            "$([[ $OVERLAY_DATA -eq 1 ]] && echo ", p4 rwdata (rest)")" >&2
    elif [[ $OVERLAY_DATA -eq 1 ]]; then
        printf "  partitions  : p1 rootfs (%s), p2 rwdata (rest, label %s)\n" "$ROOTFS_SIZE" "$RWDATA_LABEL" >&2
    else
        printf "  partitions  : p1 rootfs (whole disk)\n" >&2
    fi
    echo "==================================================" >&2
    warn "this will DESTROY ALL DATA on $DISK"
    if [[ $ASSUME_YES -ne 1 ]]; then
        local confirm=""
        read -rp "Type 'yes' to continue: " confirm
        [[ "$confirm" == "yes" ]] || die "aborted by user"
    fi

    WORKDIR="$(mktemp -d -t ecu150v2-flash-XXXXXX)"
    trap cleanup EXIT INT TERM
    local mnt="$WORKDIR/rootfs"
    mkdir -p "$mnt"

    partition_disk "$DISK"

    log "mounting ${DISK}${P}1 -> $mnt"
    mount "${DISK}${P}1" "$mnt"

    populate_rootfs "$mnt"

    log "rootfs contents:"
    ls "$mnt" | sed 's/^/    /' >&2
    if [[ -d "$mnt/boot" ]]; then
        log "/boot contents:"
        ls -lh "$mnt/boot" | sed 's/^/    /' >&2
    fi

    log "syncing and unmounting rootfs"
    sync
    umount "$mnt"

    write_bootloader "$DISK"

    log "flushing disk caches"
    blockdev --flushbufs "$DISK" 2>/dev/null || true
    sync

    ok "done — ECU-150v2 SD/eMMC ready (KVER=${KVER:-unknown})"
    echo "" >&2
    echo "  Layout:" >&2
    echo "    imx-boot     @ ${IMX_BOOT_OFFSET_KB} KiB (raw)" >&2
    if [[ $RAUC -eq 1 ]]; then
        echo "    ${DISK}${P}1 (ext4) : rootfs A, /boot/Image + dtb (flashed)" >&2
        echo "    ${DISK}${P}2 (ext4) : rootfs B (empty; 'rauc install' populates it)" >&2
        echo "    ${DISK}${P}3 (ext4) : /data (RAUC status + persistent data)" >&2
        if [[ $OVERLAY_DATA -eq 1 ]]; then
            echo "    ${DISK}${P}4 (ext4) : overlay rwdata (label ${RWDATA_LABEL})" >&2
            echo "" >&2
            echo "  For overlay root, set kernel bootargs: overlayrwdev=/dev/mmcblkXp4" >&2
        fi
    else
        echo "    ${DISK}${P}1 (ext4) : rootfs, /boot/Image + dtb" >&2
        if [[ $OVERLAY_DATA -eq 1 ]]; then
            echo "    ${DISK}${P}2 (ext4) : overlay rwdata (label ${RWDATA_LABEL})" >&2
            echo "" >&2
            echo "  For overlay root, set kernel bootargs: overlayrwdev=/dev/mmcblkXp2" >&2
        fi
    fi
    echo "" >&2
    echo "  Remove the card, insert it into the ECU-150v2, and power on." >&2
}

main "$@"
