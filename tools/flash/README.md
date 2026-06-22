# `ecu150v2_flash.sh` — SD / eMMC flashing tool

Flash an SD card or eMMC for the **Advantech ECU-150v2** (NXP i.MX8M Plus / imx8mp).

A single script covers every supported layout combination:

- **Rootfs base**: pure Yocto rootfs, or an external Ubuntu rootfs with the Yocto
  kernel modules / firmware overlaid on top.
- **Boot mode**: plain single-rootfs, or RAUC A/B (`--rauc`).
- **Root filesystem**: normal read-write, or immutable OverlayFS root (by booting the
  initramfs-bundled kernel), optionally with a dedicated persistent overlay partition
  (`--overlay-data`).

There is **no separate boot partition**: `imx-boot` is written raw at the 32 KiB
offset and partition 1 starts directly at the rootfs. U-Boot loads the kernel directly
from the rootfs `/boot/Image`.

> [!CAUTION]
> The script **wipes the entire target disk**. Double-check `--device` before running.

---

## Prerequisites

### Host tools

```console
foo@bar:~$ sudo apt-get install parted e2fsprogs zstd
```

`sudo` is required (the script re-execs itself through `sudo` if needed).

### Build artifacts

Build the image first (see the top-level manifest `README.md`). All artifacts live in
the deploy directory, which is passed once via `--images`:

```
bld-wayland/tmp/deploy/images/ecu150v2/
├── imx-image-core-ecu150v2.rootfs.tar.zst   # Yocto rootfs (always required)
├── imx-boot                                  # bootloader (symlink, auto-detected)
├── Image-ecu150v2.bin                        # plain kernel (auto-detected default)
├── Image-initramfs-ecu150v2.bin              # initramfs-bundled kernel (overlay boot)
└── imx8mp-evk-ecu150v2.dtb                   # device tree (auto-detected)
```

The external **Ubuntu** rootfs tarball (e.g. `ubuntu-24.04-arm64-generic.rootfs.tar.zst`)
is **not** produced by Yocto — build it separately (see the manifest README
"Build Debian/Ubuntu based rootfs" section) and pass it with `--ubuntu`.

---

## Option quick reference

| Option | Meaning |
| --- | --- |
| `-d, --device <dev>` | Target block device (e.g. `/dev/sdb`). Prompts if omitted. |
| `-i, --images <dir>` | Folder to resolve bare artifact names (the deploy dir). |
| `--yocto <file>` | Yocto rootfs tarball. **Always required** (modules/firmware source). |
| `--ubuntu <file>` | External Ubuntu rootfs tarball. Optional base. |
| `-k, --kernel <file>` | Kernel installed as `/boot/Image`. Point at the initramfs kernel for overlay. |
| `-D, --dtb <file>` | Device tree (auto: `imx8mp-evk-ecu150v2.dtb`). |
| `-R, --rauc` | RAUC A/B layout (`p1` rootfsA, `p2` rootfsB, `p3` /data, `[p4]` overlay). |
| `-O, --overlay-data` | Add a trailing ext4 partition for a **persistent** overlay upper/work. |
| `--rootfs-size <sz>` | Size of each rootfs partition (default `6GiB`). |
| `--data-size <sz>` | RAUC `/data` partition size (default `1GiB`). |
| `-y, --yes` | Skip the confirmation prompt. |
| `-h, --help` | Full help, including the partition design. |

Bare names (e.g. `Image-initramfs-ecu150v2.bin`) are resolved inside `--images`;
absolute / relative paths are also accepted and take priority.

---

## Step 0 — Identify the target disk

```console
foo@bar:~$ lsblk -d -p -o NAME,SIZE,MODEL,TRAN | grep -E 'usb|mmc'
```

Pick the SD card / eMMC node (e.g. `/dev/sdb`). On the target, the on-board eMMC is
always `mmcblk0` and the SD slot is always `mmcblk1`.

In every example below, `$IMAGES_DIR` is the deploy directory:

```console
foo@bar:~/yocto$ IMAGES_DIR=bld-wayland/tmp/deploy/images/ecu150v2
```

---

## Scenario 1 — Ubuntu (plain rootfs)

External Ubuntu base + Yocto kernel modules / firmware, plain kernel, single rootfs.

```
p1  ext4  rootfs (Ubuntu + Yocto modules/firmware, /boot/Image + dtb)
```

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --ubuntu ubuntu-24.04-arm64-generic.rootfs.tar.zst \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
```

The kernel defaults to the plain `Image-ecu150v2.bin`; `/sbin/init` boots directly.

---

## Scenario 2 — Ubuntu + Overlay

Same Ubuntu base, but boot the **initramfs-bundled** kernel so the overlay `/init`
takes over and the rootfs is mounted read-only.

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --ubuntu ubuntu-24.04-arm64-generic.rootfs.tar.zst \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst \
    --kernel Image-initramfs-ecu150v2.bin
```

`--kernel Image-initramfs-ecu150v2.bin` installs the initramfs kernel as `/boot/Image`.
Overlay writes land on a **volatile tmpfs** and are wiped on every reboot.

---

## Scenario 3 — Yocto rootfs + Overlay

Pure Yocto rootfs (no `--ubuntu`), initramfs kernel for overlay root.

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst \
    --kernel Image-initramfs-ecu150v2.bin
```

> [!TIP]
> If you built with `OVERLAY_INITRAMFS_ROOT = "1"`, the rootfs tarball's `/boot/Image`
> is **already** the initramfs-bundled kernel, so `--kernel` may be omitted. Passing it
> explicitly works either way and is the safe choice.

---

## Scenario 4 — Yocto rootfs + RAUC

RAUC A/B layout, plain kernel. Slot A is flashed; slot B is left empty for the first
OTA install; `/data` holds RAUC status + persistent data.

```
p1  ext4  rootfs A   (flashed)
p2  ext4  rootfs B   (empty; populated by 'rauc install')
p3  ext4  /data      (RAUC status + shared persistent data)
```

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --rauc \
    --yocto imx-image-core-ecu150v2.rootfs.tar.zst
```

After first boot, verify with `lsblk` (expect `mmcblk1p1/p2/p3`), `findmnt /`
(expect `/dev/mmcblk1p1`), and `rauc status`. For the full OTA flow see the manifest
README "RAUC OTA (A/B update)" section.

---

## Scenario 5 — Yocto rootfs + RAUC + Overlay

RAUC A/B **and** overlay root: A/B slots + `/data`, booting the initramfs kernel.
Overlay writes land on a volatile tmpfs.

```
p1  ext4  rootfs A   (flashed)
p2  ext4  rootfs B   (empty; populated by 'rauc install')
p3  ext4  /data      (RAUC status + shared persistent data)
```

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --rauc \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst \
    --kernel Image-initramfs-ecu150v2.bin
```

---

## Scenario matrix

| # | Scenario | `--ubuntu` | `--rauc` | `--kernel` (overlay) | Partitions |
| --- | --- | :---: | :---: | :---: | --- |
| 1 | Ubuntu | yes | | | `p1` |
| 2 | Ubuntu + Overlay | yes | | yes | `p1` |
| 3 | Yocto + Overlay | | | yes | `p1` |
| 4 | Yocto + RAUC | | yes | | `p1 p2 p3` |
| 5 | Yocto + RAUC + Overlay | | yes | yes | `p1 p2 p3` |

`--yocto <rootfs tarball>` is required in **all** scenarios (it provides the kernel
modules / firmware, and is the rootfs base whenever `--ubuntu` is omitted).

---

## After flashing

Remove the card, insert it into the ECU-150v2, and power on.

- **Overlay scenarios** — confirm the overlay is active on the target:

  ```console
  root@ecu150v2:~$ mount | grep overlay      # overlay on / type overlay (...)
  root@ecu150v2:~$ mount | grep ' /ro '       # real rootfs, read-only
  ```

- **RAUC scenarios** — confirm the A/B layout and status:

  ```console
  root@ecu150v2:~$ lsblk                       # expect mmcblk1p1/p2/p3
  root@ecu150v2:~$ rauc status                 # booted from rootfs.0, slot B empty
  ```

For overlay internals (development backdoor `overlayroot=disabled`) and the full RAUC
OTA workflow, see the top-level manifest `README.md`.
