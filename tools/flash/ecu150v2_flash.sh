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
# Partition layout (NO separate boot partition; p1 starts at the rootfs).
# The table is built as an ORDERED LIST, so any flag combination works:
#
#   p1    rootfs           (or rootfs A when --rauc)
#  [pN]   rootfs B         only with --rauc
#  [pN]   data             only with --rauc  (RAUC status + shared data)
#  [pN]   appdata          only with --appdata
#  [pN]   overlay rwdata   only with --overlay-data (always LAST)
#
# Every partition gets its nominal size except the LAST one, which takes the
# rest of the disk. That is the pre-existing behaviour and it is preserved.
#
# ORDER IS PART OF THE INTERFACE. Consumers address these partitions BY NUMBER,
# so reordering the list silently breaks them -- nothing here would report an
# error. The final summary prints the numbers this run actually produced; see
# tools/flash/README.md for the flags -> number table.
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
# Secure boot (HABv4) — an explicit mode, not a guess:
#
#   --secure-boot      flash the SIGNED bootloader; /boot/Image is guaranteed
#                      SIGNED too (swapped in from --images if the rootfs
#                      shipped an unsigned kernel)
#   --no-secure-boot   flash the UNSIGNED bootloader (plain/debug card);
#                      /boot/Image is guaranteed UNSIGNED too (swapped in from
#                      --images if the rootfs shipped a signed kernel)
#   (neither)          auto: infer the mode from whichever imx-boot resolves,
#                      and only report -- neither artifact's signedness is
#                      enforced or swapped in this mode
#
#   The mode matters because a build with SECURE_BOOT_ENABLED = "1" deploys BOTH
#   variants side by side under confusingly similar names:
#
#     imx-boot                          -> symlink to signed-imx-boot-*  SIGNED
#     signed-imx-boot-ecu150v2-sd.bin-flash_evk                          SIGNED
#     imx-boot-ecu150v2-sd.bin-flash_evk                                 unsigned
#
#   Without a mode switch the bare "imx-boot" symlink silently decides for you,
#   and there is no obvious way to flash a plain card from a secure deploy dir.
#   With --no-secure-boot the unsigned file is selected by name instead.
#
#   The bootloader is chosen by name, because it is written raw at 32 KiB and is
#   not part of the rootfs. The kernel starts out as whatever the build already
#   installed into the rootfs (/boot/Image, see
#   meta-ecu-150v2/recipes-core/images/imx-image-core.bbappend, which covers all
#   four SECURE_BOOT_ENABLED x OVERLAY_INITRAMFS_ROOT combinations) -- but under
#   an EXPLICIT mode it no longer just rides along: it is checked by content
#   after extraction and swapped for its signed/unsigned counterpart from
#   --images when it does not match the requested mode (variant-preserving, see
#   counterpart_kernel_name).
#
#   Why a signed-bootloader + unsigned-kernel mismatch is fatal and not merely
#   insecure: a signed bootloader was built with CONFIG_IMX_HAB=y, and NXP's
#   booti then calls authenticate_image() on every boot; imx_hab_authenticate_image()
#   verifies even on OPEN devices (it merely prints "hab fuse not enabled" first).
#   So a signed bootloader paired with an unsigned kernel does not boot at all
#   (override: --allow-unsigned). The reverse pairing (unsigned bootloader +
#   signed kernel) still boots -- HAB is simply inert -- but --no-secure-boot
#   refuses it anyway (no override) because a plain card must not carry any
#   signed artifact at all.
#
# Kernel selection — the rootfs is the starting point, the mode is authoritative:
#   auto (default)    DO NOT touch /boot/Image. Whatever the rootfs tarball ships
#                     is probed (content-based, see is_signed_kernel) and only
#                     reported -- auto makes no promise either way.
#   --secure-boot     /boot/Image MUST end up signed. If the rootfs kernel is
#                     already signed it is left alone; if not, it is SWAPPED for
#                     the signed counterpart (see counterpart_kernel_name -- the
#                     plain/initramfs variant is preserved) resolved from
#                     --images. No signed counterpart found -> refuse (override:
#                     --allow-unsigned).
#   --no-secure-boot  /boot/Image MUST end up unsigned -- a plain card must not
#                     carry a signed kernel at all. A signed rootfs kernel is
#                     SWAPPED for its unsigned counterpart from --images (variant
#                     preserved). No unsigned counterpart found -> refuse.
#   --kernel <file>   explicit override, always wins over the rootfs AND over the
#                     auto-swap above; its signedness is still validated against
#                     an explicit --secure-boot/--no-secure-boot (refuses on a
#                     mismatch; override: --allow-unsigned for the secure-boot
#                     case only -- --no-secure-boot with a signed --kernel is
#                     always a hard error, no override).
#   fallback          if the extracted rootfs has no /boot/Image at all, one is
#                     auto-detected from --images, mode-aware (signed variants in
#                     secure mode) and preferring the initramfs-bundled variant
#                     when --overlay-data was requested.
#
#   The swap always preserves the plain vs. initramfs-bundled variant of the
#   kernel already on the rootfs (matched by content against --images, see
#   identify_rootfs_kernel + counterpart_kernel_name), never just the generic
#   mode-aware ordering. Earlier versions auto-detected signed-Image-ecu150v2.bin
#   and copied it over /boot/Image unconditionally regardless of variant: on an
#   overlay + secure build that replaced the signed BUNDLED kernel with the
#   signed PLAIN one -- the board still booted and hab_status stayed clean, but
#   overlay was silently gone. The variant-preserving swap fixes that failure
#   mode while still guaranteeing the signedness the active mode requires.
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
#   # DEFAULT: non-RAUC, single rootfs, kernel taken from the rootfs as-is:
#   sudo ./ecu150v2_flash.sh -d /dev/sdX -i ~/deploy \
#       --yocto imx-image-core-ecu150v2.rootfs.tar.zst
#
#   # SECURE BOOT: signed bootloader; the signed kernel already in the rootfs is
#   # verified before anything is written:
#   sudo ./ecu150v2_flash.sh -d /dev/sdX -i ~/deploy --secure-boot \
#       --yocto imx-image-core-ecu150v2.rootfs.tar.zst
#
#   # Same deploy dir, but deliberately produce a PLAIN card (unsigned imx-boot):
#   sudo ./ecu150v2_flash.sh -d /dev/sdX -i ~/deploy --no-secure-boot \
#       --yocto imx-image-core-ecu150v2.rootfs.tar.zst
#
#   # Secure boot + overlay + RAUC A/B: no --kernel needed, the rootfs already
#   # carries signed-Image-initramfs-ecu150v2.bin:
#   sudo ./ecu150v2_flash.sh -d /dev/sdX -i ~/deploy --secure-boot --rauc \
#       --overlay-data --yocto imx-image-core-ecu150v2.rootfs.tar.zst
#
#   # External Ubuntu base + Yocto modules/firmware:
#   sudo ./ecu150v2_flash.sh -d /dev/sdX -i ~/deploy \
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
RAUC=0                     # 1 = RAUC A/B layout (rootfs A + B + data)
OVERLAY_DATA=0             # 1 = add an ext4 partition for overlay upper/work (last part)
APPDATA=0                  # 1 = add an ext4 application-data partition
ROOTFS_SIZE="6GiB"         # size of EACH rootfs partition (non-RAUC p1; RAUC each A/B slot)
DATA_SIZE="1GiB"           # RAUC data partition size
APPDATA_SIZE="2GiB"        # --appdata partition size
RWDATA_LABEL="rwdata"      # filesystem label of the overlay data partition
SECURE_BOOT_MODE="auto"    # auto | on (--secure-boot) | off (--no-secure-boot)

# Deploy-dir names of the two bootloader variants. meta-secure-boot prefixes the
# signed one and leaves the original in place, so both exist after a secure build.
IMX_BOOT_SIGNED="signed-imx-boot-ecu150v2-sd.bin-flash_evk"
IMX_BOOT_PLAIN="imx-boot-ecu150v2-sd.bin-flash_evk"

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
Usage: ecu150v2_flash.sh -d <disk> --yocto <tarball> [options]

Target: Advantech ECU-150v2 (NXP i.MX8MP / imx8mp). Default non-RAUC; --rauc for A/B.

Required:
  -d, --disk <dev>        target block device (e.g. /dev/sdb)
  --yocto, --bsp <file>   Yocto rootfs tarball (modules/firmware; base if no --ubuntu)

Secure boot (HABv4):
  -S, --secure-boot       flash the SIGNED bootloader; /boot/Image is guaranteed
                          SIGNED too (auto-swapped from --images if needed,
                          refuses if no signed counterpart exists)
  -N, --no-secure-boot    flash the UNSIGNED bootloader -- a plain/debug card,
                          even from a deploy dir that also contains signed files.
                          /boot/Image is guaranteed UNSIGNED too (auto-swapped
                          from --images if needed, refuses if it cannot be)
  (neither)               auto: infer from whichever imx-boot resolves; neither
                          artifact's signedness is enforced in this mode

Optional:
  -i, --images <dir>      folder to resolve bare artifact names (default: .)
  --ubuntu <file>         external Ubuntu rootfs tarball (base; Yocto overlaid on top)
  -k, --kernel <file>     override /boot/Image. NOT needed for a normal Yocto
                          rootfs: under --secure-boot/--no-secure-boot the
                          right kernel is auto-swapped in from --images when
                          the rootfs shipped the wrong signedness; --kernel is
                          only for an --ubuntu base with no usable /boot, or to
                          force a specific image (its signedness is still
                          checked against an explicit mode).
  -D, --dtb <file>        DTB -> /boot (auto: imx8mp-evk-ecu150v2.dtb)
  -B, --imx-boot <file>   explicit bootloader path; overrides the mode's choice
  -R, --rauc              RAUC A/B layout (rootfs A + rootfs B + data partition)
  -O, --overlay-data      add an ext4 partition for overlay upper/work (last partition)
  -A, --appdata[=SIZE]    add an ext4 application-data partition (default: 2GiB).
                          Just a partition: mkfs'd like every other one, and
                          nothing is written to it. Whoever owns it decides what
                          it becomes -- this tool does not care.
  --rootfs-size <sz>      size of each rootfs partition (default: 6GiB)
  --data-size <sz>        RAUC data partition size (default: 1GiB; --rauc only)
  --appdata-size <sz>     application-data partition size (default: 2GiB)
  --offset <kb>           imx-boot raw offset in KiB (default: 32)
  --part-start <sz>       first partition start (default: 8MiB)
  -y, --yes               do not prompt for confirmation
  --allow-unsigned        proceed even when a SIGNED bootloader is paired with an
                          unsigned kernel. That combination does NOT boot (booti
                          authenticates the kernel whenever CONFIG_IMX_HAB=y, open
                          devices included) -- debug use only.
  -h, --help              show this help

How the secure-boot mode is applied:
  The bootloader is chosen by name, because it is written raw at 32 KiB and is
  not part of the rootfs:
      --secure-boot     -> signed-imx-boot-ecu150v2-sd.bin-flash_evk
      --no-secure-boot  -> imx-boot-ecu150v2-sd.bin-flash_evk (refuses a signed one)
      auto              -> the "imx-boot" symlink, whatever the build pointed it at
  The kernel (/boot/Image, probed by content -- arm64 image_size offset -> IVT
  header) is actively enforced under an EXPLICIT mode:
      --secure-boot     -> must end up signed; an unsigned rootfs kernel is
                           swapped for its signed counterpart from --images
                           (same plain/initramfs variant), or the flash refuses
                           (override: --allow-unsigned).
      --no-secure-boot  -> must end up unsigned; a signed rootfs kernel is
                           swapped for its unsigned counterpart from --images
                           (same variant), or the flash refuses (no override).
      auto              -> not enforced; whatever the rootfs ships is reported
                           as-is, matching whatever --imx-boot resolved to.
  Either way the check/swap runs BEFORE the bootloader is written, so a refusal
  leaves a card with no bootloader instead of a subtly broken one.

Partition design (NO separate boot partition; imx-boot is raw at 32 KiB,
p1 starts directly at the rootfs). Built as an ORDERED LIST, so any flag
combination works:

    p1    rootfs                       (/boot/Image + /boot/*.dtb; rootfs A with --rauc)
   [pN]   rootfs B                     only with --rauc (empty; 'rauc install' fills it)
   [pN]   data                         only with --rauc (RAUC status + shared data)
   [pN]   appdata                      only with --appdata
   [pN]   overlay rwdata               only with --overlay-data (always LAST)

  Every partition gets its nominal size except the LAST one, which takes the
  rest of the disk.

  ORDER IS PART OF THE INTERFACE: consumers address these BY NUMBER, so the
  numbers shift when you change flags. The final summary prints the numbers this
  run actually produced -- read it, do not guess.
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

# ----------------------------------------------------------------------------
# Secure boot (HABv4) detection
# ----------------------------------------------------------------------------
# A HABv4-signed arm64 kernel is laid out as
#     [ Image padded to the arm64 header's image_size ][ 32-byte IVT ][ CSF ]
# so the IVT header (tag 0xD1 + big-endian length 0x0020) sits exactly at the
# image_size offset. That makes this a content-based test, not a name guess.
# (Same offset linux-imx-signature.bb uses: od -An -j 16 -N 4 -i.)
is_signed_kernel() {
    local f="$1" pad size hdr
    [[ -f "$f" ]] || return 1
    # arm64 header: image_size is a little-endian u64 at offset 0x10.
    pad="$(od -An -t u4 -j 16 -N 4 -- "$f" 2>/dev/null | tr -d '[:space:]')"
    [[ "$pad" =~ ^[1-9][0-9]*$ ]] || return 1
    size="$(stat -Lc%s -- "$f" 2>/dev/null)" || return 1
    (( pad + 32 <= size )) || return 1
    hdr="$(od -An -t x1 -j "$pad" -N 3 -- "$f" 2>/dev/null | tr -d '[:space:]')"
    [[ "$hdr" == "d10020" ]]
}

# imx-boot has no cheap content test: its CSF is inserted into pre-reserved
# padding, so the signed file is byte-for-byte the same SIZE as the unsigned
# one. Fall back to the deploy name that meta-nxp-security-reference-design
# gives it (signed-imx-boot-*), which resolve_artifact() reaches through the
# imx-boot symlink. Authoritative check: works/habv4parser/habtool.py --check
looks_signed_bootloader() {
    [[ "${1##*/}" == signed-* ]]
}

# Pick the bootloader for the requested mode. --imx-boot always wins; without it
# "on"/"off" select the variant by name and "auto" keeps the historical default
# of following the bare imx-boot symlink.
resolve_bootloader() {
    local want="$1" p
    case "$want" in
        on)
            p="$(resolve_artifact "$IMX_BOOT_SIGNED")"
            [[ -f "$p" ]] || die "--secure-boot: $IMX_BOOT_SIGNED not found in $IMAGES
  Build with SECURE_BOOT_ENABLED = \"1\" first, or pass --imx-boot <path>."
            ;;
        off)
            p="$(resolve_artifact "$IMX_BOOT_PLAIN")"
            [[ -f "$p" ]] || die "--no-secure-boot: $IMX_BOOT_PLAIN not found in $IMAGES
  Pass --imx-boot <path> to name the unsigned bootloader explicitly."
            # meta-secure-boot signs imx-boot in place inside pre-reserved padding,
            # so the signed file is the same SIZE as the unsigned one and there is
            # no content test to fall back on -- the name is all we have.
            if [[ "$(readlink -f "$p")" == *"/signed-"* ]]; then
                die "--no-secure-boot: $IMX_BOOT_PLAIN resolves to a signed file
  ($(readlink -f "$p")) -- cannot produce a plain card from this deploy dir."
            fi
            ;;
        *)
            p="$(resolve_artifact "$IMX_BOOT")"
            ;;
    esac
    printf '%s' "$p"
}

# Name the kernel sitting in the extracted rootfs by comparing it against the
# deploy-dir candidates. Size is checked first so cmp only reads a 40+ MB file
# when it can actually match. Echoes the artifact name, or nothing.
identify_rootfs_kernel() {
    local k="$1" ksize cand cpath
    ksize="$(stat -Lc%s -- "$k" 2>/dev/null)" || return 0
    for cand in "signed-Image-initramfs-ecu150v2.bin" "signed-Image-ecu150v2.bin" \
                "Image-initramfs-ecu150v2.bin" "Image-ecu150v2.bin"; do
        cpath="$(resolve_artifact "$cand")"
        [[ -f "$cpath" ]] || continue
        [[ "$(stat -Lc%s -- "$cpath" 2>/dev/null)" == "$ksize" ]] || continue
        if cmp -s -- "$k" "$cpath"; then printf '%s' "$cand"; return 0; fi
    done
    return 0
}

# Given a deploy-artifact kernel name, return the name of its signed/unsigned
# counterpart, preserving the plain vs. initramfs-bundled variant. Used to swap
# the rootfs kernel to match an explicit --secure-boot/--no-secure-boot mode
# WITHOUT ever changing plain<->initramfs (that silent downgrade is exactly the
# "Earlier versions" bug described above populate_rootfs()).
counterpart_kernel_name() {
    local n="$1"
    if [[ "$n" == signed-* ]]; then
        printf '%s' "${n#signed-}"
    else
        printf '%s' "signed-${n}"
    fi
}

# Auto-detect a kernel from --images. Only used when the extracted rootfs has no
# /boot/Image at all (e.g. an --ubuntu base without a usable /boot), or as a
# fallback when the current kernel's exact variant could not be identified by
# content. Order is mode-aware, and --overlay-data is taken as a request for
# the bundled variant.
autodetect_kernel() {
    local order=() n p
    if [[ $OVERLAY_DATA -eq 1 ]]; then
        order=(signed-Image-initramfs-ecu150v2.bin Image-initramfs-ecu150v2.bin
               signed-Image-ecu150v2.bin Image-ecu150v2.bin)
    else
        order=(signed-Image-ecu150v2.bin Image-ecu150v2.bin
               signed-Image-initramfs-ecu150v2.bin Image-initramfs-ecu150v2.bin)
    fi
    # In an explicit mode, only consider the matching variant: a signed kernel is
    # useless without a HAB bootloader, and an unsigned one cannot boot with one.
    for n in "${order[@]}"; do
        if [[ "$SECURE_BOOT_MODE" == "on"  && "$n" != signed-* ]]; then continue; fi
        if [[ "$SECURE_BOOT_MODE" == "off" && "$n" == signed-* ]]; then continue; fi
        p="$(resolve_artifact "$n")"
        if [[ -f "$p" ]]; then printf '%s' "$p"; return 0; fi
    done
    return 0
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
# Build the partition table as an ordered list. Three parallel arrays, one entry
# per partition, index+1 == partition number. Everything downstream (mkfs, both
# summaries, the overlay bootargs hint) walks this list, so a layout change can
# never drift out of sync with what gets printed.
PART_LABEL=()   # ext4 label
PART_SIZE=()    # size in MiB, or "REST" for the last entry
PART_DISP=()    # size as shown to the user
PART_NOTE=()    # what the partition is for

plan_partitions() {
    PART_LABEL=(); PART_SIZE=(); PART_DISP=(); PART_NOTE=()

    if [[ $RAUC -eq 1 ]]; then
        PART_LABEL+=("rootfs_a"); PART_SIZE+=("$(to_mib "$ROOTFS_SIZE")")
        PART_DISP+=("$ROOTFS_SIZE"); PART_NOTE+=("rootfs A, /boot/Image + dtb (flashed)")
        PART_LABEL+=("rootfs_b"); PART_SIZE+=("$(to_mib "$ROOTFS_SIZE")")
        PART_DISP+=("$ROOTFS_SIZE"); PART_NOTE+=("rootfs B (empty; 'rauc install' populates it)")
        PART_LABEL+=("data");     PART_SIZE+=("$(to_mib "$DATA_SIZE")")
        PART_DISP+=("$DATA_SIZE"); PART_NOTE+=("RAUC status + persistent data")
    else
        PART_LABEL+=("rootfs");   PART_SIZE+=("$(to_mib "$ROOTFS_SIZE")")
        PART_DISP+=("$ROOTFS_SIZE"); PART_NOTE+=("rootfs, /boot/Image + dtb")
    fi

    if [[ $APPDATA -eq 1 ]]; then
        PART_LABEL+=("appdata"); PART_SIZE+=("$(to_mib "$APPDATA_SIZE")")
        PART_DISP+=("$APPDATA_SIZE"); PART_NOTE+=("empty; for application data")
    fi

    if [[ $OVERLAY_DATA -eq 1 ]]; then
        PART_LABEL+=("$RWDATA_LABEL"); PART_SIZE+=("0")
        PART_DISP+=("rest"); PART_NOTE+=("overlay upper/work")
    fi

    # Pre-existing behaviour, kept deliberately: the last partition always takes
    # the rest of the disk, whatever it happens to be.
    local last=$(( ${#PART_SIZE[@]} - 1 ))
    PART_SIZE[$last]="REST"
    PART_DISP[$last]="rest"
}

# Echo the 1-based partition number carrying $1, or return 1 if there is none.
part_num_of() {
    local want="$1" i
    for (( i = 0; i < ${#PART_LABEL[@]}; i++ )); do
        if [[ "${PART_LABEL[i]}" == "$want" ]]; then printf '%s' "$((i + 1))"; return 0; fi
    done
    return 1
}

# The layout-affecting flags of this run, for the summary.
layout_flags() {
    local f=""
    if [[ $RAUC -eq 1 ]];         then f+=" --rauc"; fi
    if [[ $APPDATA -eq 1 ]];      then f+=" --appdata"; fi
    if [[ $OVERLAY_DATA -eq 1 ]]; then f+=" --overlay-data"; fi
    printf '%s' "${f:- (none)}"
}

# Partition the disk from the plan_partitions() list. No separate boot partition:
# imx-boot is raw at 32 KiB, so p1 starts directly at the rootfs.
partition_disk() {
    local disk="$1"

    log "unmounting any existing partitions on $disk"
    umount "${disk}"* 2>/dev/null || true

    log "wiping first ${WIPE_MIB} MiB of $disk"
    dd if=/dev/zero of="$disk" bs=1M count="$WIPE_MIB" conv=fsync status=none
    sync

    local i n start end
    start="$(to_mib "$PART_START")"
    n=${#PART_LABEL[@]}

    log "layout:$(layout_flags) -> ${n} partition(s)"

    parted -s "$disk" mklabel msdos
    for (( i = 0; i < n; i++ )); do
        if [[ "${PART_SIZE[i]}" == "REST" ]]; then
            parted -s "$disk" mkpart primary ext4 "${start}MiB" 100%
        else
            end=$(( start + PART_SIZE[i] ))
            parted -s "$disk" mkpart primary ext4 "${start}MiB" "${end}MiB"
            start=$end
        fi
    done
    parted -s "$disk" set 1 boot on

    # Let the kernel re-read the new table before mkfs.
    sync
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 1

    for (( i = 0; i < n; i++ )); do
        log "formatting ${disk}${P}$((i + 1)) (ext4, label ${PART_LABEL[i]}, ${PART_DISP[i]})"
        mkfs.ext4 -F -L "${PART_LABEL[i]}" "${disk}${P}$((i + 1))"
    done
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

# Inspect the kernel that will actually boot and hold it against the secure-boot
# mode. Runs on the mounted rootfs -- after every substitution, so it sees the
# final state rather than guessing from filenames in the deploy dir. Called
# BEFORE write_bootloader(), so a refusal leaves a card with no bootloader (and
# hence obviously non-bootable) instead of a subtly broken one.
verify_rootfs_kernel() {
    # Two statements on purpose: within one `local` the earlier name is not yet
    # assigned, so "local mnt=$1 k=$mnt/..." trips set -u.
    local mnt="$1"
    local k="$mnt/boot/Image"

    # No kernel at all: only expected for an --ubuntu base whose /boot is unusable.
    if [[ ! -f "$k" ]]; then
        local fallback
        fallback="$(autodetect_kernel)"
        if [[ -z "$fallback" ]]; then
            die "the rootfs has no /boot/Image and no usable kernel was found in $IMAGES
  Pass --kernel <image> explicitly."
        fi
        warn "the rootfs has no /boot/Image; installing ${fallback##*/} from --images"
        install -d "$mnt/boot"
        cp -L "$fallback" "$k"
    fi

    SB_KERNEL=0
    if is_signed_kernel "$k"; then SB_KERNEL=1; fi
    ROOTFS_KERNEL_NAME="$(identify_rootfs_kernel "$k")"

    # Under an EXPLICIT mode, /boot/Image's signedness is not just reported, it
    # is enforced: swap in the matching counterpart from --images when the
    # rootfs shipped the wrong one. --kernel overrides skip this entirely --
    # main() already validated (and, for --no-secure-boot, hard-refused) that
    # explicit choice, so it is never touched here.
    if [[ -z "$KERNEL_IMAGE" ]]; then
        if [[ "$SECURE_BOOT_MODE" == "off" && $SB_KERNEL -eq 1 ]]; then
            local plain=""
            if [[ -n "$ROOTFS_KERNEL_NAME" ]]; then
                plain="$(resolve_artifact "$(counterpart_kernel_name "$ROOTFS_KERNEL_NAME")")"
                [[ -f "$plain" ]] || plain=""
            fi
            [[ -n "$plain" ]] || plain="$(autodetect_kernel)"
            if [[ -z "$plain" ]]; then
                die "--no-secure-boot: /boot/Image from the rootfs is SIGNED (${ROOTFS_KERNEL_NAME:-unidentified}) and no unsigned counterpart was found in $IMAGES.
  A plain card must not carry any signed kernel. Add Image-ecu150v2.bin /
  Image-initramfs-ecu150v2.bin to --images, or pass --kernel <unsigned image>."
            fi
            warn "--no-secure-boot: /boot/Image is SIGNED (${ROOTFS_KERNEL_NAME:-unidentified}); swapping in ${plain##*/}"
            install -d "$mnt/boot"
            cp -L "$plain" "$k"
            SB_KERNEL=0
            ROOTFS_KERNEL_NAME="$(identify_rootfs_kernel "$k")"
        elif [[ "$SECURE_BOOT_MODE" == "on" && $SB_KERNEL -eq 0 ]]; then
            local signed=""
            if [[ -n "$ROOTFS_KERNEL_NAME" ]]; then
                signed="$(resolve_artifact "$(counterpart_kernel_name "$ROOTFS_KERNEL_NAME")")"
                [[ -f "$signed" ]] || signed=""
            fi
            [[ -n "$signed" ]] || signed="$(autodetect_kernel)"
            if [[ -n "$signed" ]]; then
                warn "--secure-boot: /boot/Image is unsigned (${ROOTFS_KERNEL_NAME:-unidentified}); swapping in ${signed##*/}"
                install -d "$mnt/boot"
                cp -L "$signed" "$k"
                SB_KERNEL=1
                ROOTFS_KERNEL_NAME="$(identify_rootfs_kernel "$k")"
            fi
            # No signed counterpart found: fall through, the fatal check below
            # refuses (or proceeds with --allow-unsigned).
        fi
    fi

    log "/boot/Image: $([[ $SB_KERNEL -eq 1 ]] && echo SIGNED || echo unsigned)$([[ -n "$ROOTFS_KERNEL_NAME" ]] && echo ", matches ${ROOTFS_KERNEL_NAME}")"
    if [[ "$ROOTFS_KERNEL_NAME" == *initramfs* ]]; then
        log "  initramfs-bundled -> overlay/immutable root is available"
    fi

    # The fatal pairing: a signed bootloader means CONFIG_IMX_HAB=y, and NXP's
    # booti then calls authenticate_image() on every boot (cmd/booti.c). Even on
    # an OPEN device imx_hab_authenticate_image() merely prints "hab fuse not
    # enabled" and verifies anyway, so an unsigned kernel is fatal here.
    if [[ $SB_BOOTLOADER -eq 1 && $SB_KERNEL -eq 0 ]]; then
        err "secure boot mismatch: bootloader is SIGNED but /boot/Image is NOT."
        err "  bootloader : ${IMX_BOOT##*/}"
        if [[ -n "$KERNEL_IMAGE" ]]; then
            err "  kernel     : ${KERNEL_IMAGE##*/}  (installed via --kernel)"
        else
            err "  kernel     : /boot/Image from the rootfs tarball ${BSP##*/}"
        fi
        err "This pair does NOT boot -- booti authenticates the kernel on every boot,"
        err "OPEN devices included."
        if [[ -n "$KERNEL_IMAGE" ]]; then
            err "Fix: drop --kernel so the rootfs kernel is kept, or point it at a signed-* image."
        else
            err "No signed counterpart was found in $IMAGES to auto-swap in either, so the"
            err "BUILD is what needs fixing:"
            err "  * SECURE_BOOT_ENABLED = \"1\" must be set in bld-wayland/conf/local.conf, and"
            err "  * meta-secure-boot must be in BBLAYERS (sources/meta-ecu-150v2/scripts/ecu150v2-setup.sh)"
            err "  so imx-image-core.bbappend can install signed-Image*.bin into /boot/Image."
            err "Or flash a plain card instead: --no-secure-boot."
        fi
        [[ $ALLOW_UNSIGNED -eq 1 ]] || die "refusing to flash an unbootable card (override: --allow-unsigned)"
        warn "--allow-unsigned given: proceeding; expect 'Authenticate Image Fail' on boot"
    fi

    # Only reachable in "auto" mode: an explicit --no-secure-boot already forced
    # SB_KERNEL back to 0 above (swap-or-die), so this combination cannot occur
    # there any more.
    if [[ $SB_BOOTLOADER -eq 0 && $SB_KERNEL -eq 1 ]]; then
        warn "/boot/Image is signed but ${IMX_BOOT##*/} does not look signed."
        warn "  This still boots, but you are NOT getting secure boot."
        warn "  Use --secure-boot to write $IMX_BOOT_SIGNED instead, or --no-secure-boot"
        warn "  to also swap the kernel for an unsigned one."
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
IMX_BOOT_EXPLICIT=0        # 1 = --imx-boot was given, so do not let the mode pick
ASSUME_YES=0
ALLOW_UNSIGNED=0           # 1 = do not refuse a signed-bootloader + unsigned-kernel mix
KVER=""
SB_BOOTLOADER=0            # 1 = the imx-boot being written looks HABv4-signed
SB_KERNEL=0                # 1 = the /boot/Image on the card is HABv4-signed
ROOTFS_KERNEL_NAME=""      # deploy artifact the rootfs /boot/Image matched, if any

main() {
    ORIG_ARGS=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--disk|--device) DISK="${2:-}"; shift 2 ;;
            -i|--images)        IMAGES="${2:-}"; shift 2 ;;
            -u|--ubuntu)        UBUNTU="${2:-}"; shift 2 ;;
            -b|--bsp|--yocto)   BSP="${2:-}"; shift 2 ;;
            -B|--imx-boot)      IMX_BOOT="${2:-}"; IMX_BOOT_EXPLICIT=1; shift 2 ;;
            -k|--kernel|--image) KERNEL_IMAGE="${2:-}"; shift 2 ;;
            -D|--dtb)           DTB_FILE="${2:-}"; shift 2 ;;
            -R|--rauc)          RAUC=1; shift ;;
            -O|--overlay-data)  OVERLAY_DATA=1; shift ;;
            -A|--appdata)       APPDATA=1; shift ;;
            --appdata=*)        APPDATA=1; APPDATA_SIZE="${1#*=}"; shift ;;
            -S|--secure-boot)    SECURE_BOOT_MODE="on"; shift ;;
            -N|--no-secure-boot) SECURE_BOOT_MODE="off"; shift ;;
            --secure-boot=*)
                SECURE_BOOT_MODE="${1#*=}"
                case "$SECURE_BOOT_MODE" in
                    on|off|auto) ;;
                    yes|true|1)  SECURE_BOOT_MODE="on" ;;
                    no|false|0)  SECURE_BOOT_MODE="off" ;;
                    *) die "--secure-boot=: expected on|off|auto, got '${1#*=}'" ;;
                esac
                shift ;;
            --rootfs-size)      ROOTFS_SIZE="${2:-}"; shift 2 ;;
            --data-size)        DATA_SIZE="${2:-}"; shift 2 ;;
            --appdata-size)     APPDATA_SIZE="${2:-}"; shift 2 ;;
            --offset)           IMX_BOOT_OFFSET_KB="${2:-}"; shift 2 ;;
            --part-start)       PART_START="${2:-}"; shift 2 ;;
            -y|--yes)           ASSUME_YES=1; shift ;;
            --allow-unsigned)   ALLOW_UNSIGNED=1; shift ;;
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
    [[ -f "$BSP" ]] || die "Yocto rootfs not found: $BSP"

    # ---- Bootloader: the one artifact the secure-boot mode selects -----------
    if [[ $IMX_BOOT_EXPLICIT -eq 1 ]]; then
        IMX_BOOT="$(resolve_artifact "$IMX_BOOT")"
        [[ -f "$IMX_BOOT" ]] || die "imx-boot not found: $IMX_BOOT"
    else
        IMX_BOOT="$(resolve_bootloader "$SECURE_BOOT_MODE")"
        [[ -f "$IMX_BOOT" ]] || die "imx-boot not found: $IMX_BOOT (use --imx-boot or put it in --images)"
    fi

    SB_BOOTLOADER=0
    if looks_signed_bootloader "$IMX_BOOT"; then SB_BOOTLOADER=1; fi

    case "$SECURE_BOOT_MODE" in
        on)
            # Only reachable via --imx-boot, since resolve_bootloader() picks by name.
            [[ $SB_BOOTLOADER -eq 1 ]] || die "--secure-boot but ${IMX_BOOT##*/} is not a signed-* file
  Drop --imx-boot to let the mode pick $IMX_BOOT_SIGNED."
            log "secure boot ON: writing ${IMX_BOOT##*/}"
            ;;
        off)
            if [[ $SB_BOOTLOADER -eq 1 ]]; then
                die "--no-secure-boot but ${IMX_BOOT##*/} is a signed bootloader
  Drop --imx-boot to let the mode pick $IMX_BOOT_PLAIN."
            fi
            log "secure boot OFF: writing ${IMX_BOOT##*/} (plain card)"
            ;;
        *)
            # Historical default: follow the bare imx-boot symlink and report what
            # the build pointed it at, so the mode is at least visible.
            log "secure boot mode: auto -> ${IMX_BOOT##*/} ($([[ $SB_BOOTLOADER -eq 1 ]] && echo SIGNED || echo unsigned))"
            log "  (pass --secure-boot / --no-secure-boot to choose explicitly)"
            ;;
    esac

    # --ubuntu is optional: when omitted, the Yocto rootfs is the base.
    if [[ -n "$UBUNTU" ]]; then
        UBUNTU="$(resolve_artifact "$UBUNTU")"
        [[ -f "$UBUNTU" ]] || die "Ubuntu rootfs not found: $UBUNTU"
    fi

    # ---- Kernel: not selected here, but enforced under an explicit mode ------
    # Left alone by default -- the rootfs already carries the right /boot/Image
    # for the build that made it (imx-image-core.bbappend covers all four toggle
    # combinations). Under an explicit --secure-boot/--no-secure-boot, though,
    # verify_rootfs_kernel() actively swaps in a matching-variant counterpart
    # from --images when the rootfs shipped the wrong signedness (see the
    # "Kernel selection" note near the top of the file). --kernel is an explicit
    # override that always wins over that swap; its own signedness is validated
    # right here, against whichever mode was requested.
    if [[ -n "$KERNEL_IMAGE" ]]; then
        KERNEL_IMAGE="$(resolve_artifact "$KERNEL_IMAGE")"
        [[ -f "$KERNEL_IMAGE" ]] || die "kernel image not found: $KERNEL_IMAGE"
        warn "--kernel given: /boot/Image from the rootfs will be REPLACED by ${KERNEL_IMAGE##*/}"
        if [[ "$SECURE_BOOT_MODE" == "on" ]] && ! is_signed_kernel "$KERNEL_IMAGE"; then
            err "--secure-boot with an unsigned --kernel: ${KERNEL_IMAGE##*/}"
            err "  A signed bootloader authenticates the kernel on every boot, OPEN devices"
            err "  included, so this will stop at 'Authenticate Image Fail'."
            err "  Fix: drop --kernel and let the rootfs kernel be used, or point it at"
            err "       signed-Image-ecu150v2.bin / signed-Image-initramfs-ecu150v2.bin."
            [[ $ALLOW_UNSIGNED -eq 1 ]] || die "refusing (override: --allow-unsigned)"
            warn "--allow-unsigned given: proceeding anyway"
        fi
        if [[ "$SECURE_BOOT_MODE" == "off" ]] && is_signed_kernel "$KERNEL_IMAGE"; then
            die "--no-secure-boot with a SIGNED --kernel: ${KERNEL_IMAGE##*/}
  A plain card must not carry any signed kernel -- this is a hard error, no
  --allow-unsigned override. Point --kernel at an unsigned image
  (Image-ecu150v2.bin / Image-initramfs-ecu150v2.bin), or drop --kernel and
  let the rootfs kernel be auto-swapped to its unsigned counterpart instead."
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
    printf "  kernel Image: %s\n" "${KERNEL_IMAGE:-(keeping /boot/Image from the rootfs)}" >&2
    printf "  DTB         : %s\n" "${DTB_FILE:-(from rootfs tarball)}" >&2
    printf "  imx-boot    : %s  (@ %s KiB)\n" "$IMX_BOOT" "$IMX_BOOT_OFFSET_KB" >&2
    printf "  secure boot : %s  (bootloader %s; kernel checked after extraction)\n" \
        "$(case "$SECURE_BOOT_MODE" in on) echo 'ON  (--secure-boot)';; off) echo 'OFF (--no-secure-boot)';; *) echo 'auto';; esac)" \
        "$([[ $SB_BOOTLOADER -eq 1 ]] && echo 'SIGNED' || echo 'unsigned')" >&2
    printf "  part start  : %s\n" "$PART_START" >&2
    plan_partitions
    local pi
    for (( pi = 0; pi < ${#PART_LABEL[@]}; pi++ )); do
        if [[ $pi -eq 0 ]]; then printf "  partitions  :" >&2; else printf "                " >&2; fi
        printf " p%d %s (%s)\n" "$((pi + 1))" "${PART_LABEL[pi]}" "${PART_DISP[pi]}" >&2
    done
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

    # Content-based secure-boot check on the kernel that will really boot. Placed
    # before write_bootloader() so a refusal leaves the card without a bootloader.
    verify_rootfs_kernel "$mnt"

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
    local si num
    for (( si = 0; si < ${#PART_LABEL[@]}; si++ )); do
        printf "    %s%s%d (ext4) : %-9s %-5s %s\n" \
            "$DISK" "$P" "$((si + 1))" \
            "${PART_LABEL[si]}" "${PART_DISP[si]}" "${PART_NOTE[si]}" >&2
    done
    # Consumers address partitions BY NUMBER and the numbers move with the flags,
    # so print the ones this run actually produced instead of a fixed guess.
    if num="$(part_num_of appdata)"; then
        echo "" >&2
        echo "    appdata is partition ${num} (flags:$(layout_flags))" >&2
        echo "    Change the flags -> the number changes. See README for the table." >&2
    fi
    if num="$(part_num_of "$RWDATA_LABEL")"; then
        echo "" >&2
        echo "    For overlay root, set kernel bootargs: overlayrwdev=/dev/mmcblkXp${num}" >&2
    fi
    echo "" >&2
    if [[ $SB_BOOTLOADER -eq 1 ]]; then
        echo "  Secure boot: ENABLED on this card" >&2
        echo "    bootloader : ${IMX_BOOT##*/} (SIGNED)" >&2
        echo "    /boot/Image: $([[ $SB_KERNEL -eq 1 ]] && echo SIGNED || echo unsigned)${ROOTFS_KERNEL_NAME:+ (${ROOTFS_KERNEL_NAME})}" >&2
        echo "    On the U-Boot console, 'hab_status' must report No HAB Events Found!" >&2
        echo "    before burning SRK_HASH or closing the device (both irreversible)." >&2
        echo "" >&2
    elif [[ $SB_KERNEL -eq 1 ]]; then
        echo "  Secure boot: NOT active (unsigned bootloader; the signed kernel's IVT+CSF" >&2
        echo "    is simply ignored by a non-HAB U-Boot). Use --secure-boot for a secure card." >&2
        echo "" >&2
    fi
    echo "  Remove the card, insert it into the ECU-150v2, and power on." >&2
}

main "$@"
