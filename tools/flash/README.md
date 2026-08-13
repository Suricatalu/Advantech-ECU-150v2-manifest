# `ecu150v2_flash.sh` — SD / eMMC flashing tool

Flash an SD card or eMMC for the **Advantech ECU-150v2** (NXP i.MX8M Plus / imx8mp).

A single script covers every supported layout combination:

- **Rootfs base**: pure Yocto rootfs, or an external Ubuntu rootfs with the Yocto
  kernel modules / firmware overlaid on top.
- **Boot mode**: plain single-rootfs, or RAUC A/B (`--rauc`).
- **Root filesystem**: normal read-write, or immutable OverlayFS root (by booting the
  initramfs-bundled kernel).
- **Application data**: optionally a dedicated `appdata` partition (`--appdata`), for
  whatever the product needs to keep apart from the rootfs.
- **Secure boot**: HABv4 signed or plain, chosen explicitly with
  `--secure-boot` / `--no-secure-boot` (see [Secure boot](#secure-boot-habv4)).

There is **no separate boot partition**: `imx-boot` is written raw at the 32 KiB
offset and partition 1 starts directly at the rootfs. U-Boot loads the kernel directly
from the rootfs `/boot/Image` — by default the rootfs decides which kernel boots, but
under an explicit `--secure-boot` / `--no-secure-boot` the script actively enforces (and,
if needed, swaps) the kernel's signedness too (see [Secure boot](#secure-boot-habv4)).

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
├── imx-boot                                  # bootloader (symlink)
├── imx-boot-ecu150v2-sd.bin-flash_evk        # bootloader (the real file)
├── Image-ecu150v2.bin                        # plain kernel
├── Image-initramfs-ecu150v2.bin              # initramfs-bundled kernel (overlay builds)
└── imx8mp-evk-ecu150v2.dtb                   # device tree (auto-detected)
```

A build with `SECURE_BOOT_ENABLED = "1"` adds **signed** artifacts alongside the
unsigned ones, with deliberately similar names:

```
├── imx-boot                    -> signed-imx-boot-ecu150v2-sd.bin-flash_evk   # SIGNED
├── signed-imx-boot-ecu150v2-sd.bin-flash_evk                                  # SIGNED
├── imx-boot-ecu150v2-sd.bin-flash_evk                                         # unsigned
├── signed-Image-ecu150v2.bin                                                  # SIGNED
├── signed-Image-initramfs-ecu150v2.bin       # SIGNED (only on overlay builds)
└── Image-ecu150v2.bin          -> Image--<version>-<stamp>.bin                # unsigned!
```

Note that `Image-ecu150v2.bin` stays **unsigned** — the signing recipe adds a new
`signed-` file rather than replacing anything.

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
| `-S, --secure-boot` | Write the **signed** bootloader; `/boot/Image` is guaranteed **signed** too (auto-swapped from `--images` if the rootfs shipped an unsigned one). |
| `-N, --no-secure-boot` | Write the **unsigned** bootloader — a plain card, even from a secure deploy dir; `/boot/Image` is guaranteed **unsigned** too (auto-swapped from `--images` if needed). |
| `-k, --kernel <file>` | Override `/boot/Image`, bypassing the auto-swap above. **Not needed for a Yocto rootfs** — see below. |
| `-D, --dtb <file>` | Device tree (auto: `imx8mp-evk-ecu150v2.dtb`). |
| `-R, --rauc` | RAUC A/B layout: a second rootfs slot plus a `data` partition. |
| `-A, --appdata[=SIZE]` | Add an ext4 `appdata` partition (default `2GiB`). See [Application data partition](#application-data-partition---appdata). |
| `--rootfs-size <sz>` | Size of each rootfs partition (default `6GiB`). |
| `--data-size <sz>` | RAUC `data` partition size (default `1GiB`). |
| `--appdata-size <sz>` | `appdata` partition size (default `2GiB`). |
| `-B, --imx-boot <file>` | Explicit bootloader path; overrides what the secure-boot mode would pick. |
| `-y, --yes` | Skip the confirmation prompt. |
| `--allow-unsigned` | Proceed even with a signed bootloader + unsigned kernel. That pair **does not boot** — debug only. See [Secure boot](#secure-boot-habv4). |
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

This is a case where `--kernel` **is** the right tool: an Ubuntu base has its own
`/boot`, so the script cannot rely on the rootfs having the kernel you want. Overlay
writes land on a **volatile tmpfs** and are wiped on every reboot.

---

## Scenario 3 — Yocto rootfs + Overlay

Pure Yocto rootfs (no `--ubuntu`), built with `OVERLAY_INITRAMFS_ROOT = "1"`.

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
```

> [!TIP]
> **No `--kernel` here.** The overlay build already puts the initramfs-bundled kernel
> into the rootfs `/boot/Image`, and the script keeps it. 

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
Overlay writes land on a volatile tmpfs. Built with `OVERLAY_INITRAMFS_ROOT = "1"`.

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

Again no `--kernel`: the bundled kernel is already in the rootfs, and that is also
what the RAUC bundle carries into slot B.

---

## Scenario 6 — Yocto rootfs + Secure boot

Plain single rootfs, no RAUC, no overlay — just add `--secure-boot`:

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --secure-boot \
    --yocto imx-image-core-ecu150v2.rootfs.tar.zst
```

### Flashing a plain card from a secure deploy dir

A secure build leaves **both** bootloaders in the deploy directory, and `imx-boot` is
a symlink to the signed one. Without a flag you would silently get a secure card. Use
`--no-secure-boot` to pick the unsigned bootloader by name — and it also makes sure the
card ends up with an **unsigned** kernel, not just an unsigned bootloader:

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX --images "$IMAGES_DIR" --no-secure-boot \
    --yocto imx-image-core-ecu150v2.rootfs.tar.zst
```

---

## Scenario 7 — Yocto rootfs + Overlay + Secure boot

Same as Scenario 3, signed: overlay build, just add `--secure-boot`:

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --secure-boot \
    --yocto imx-image-core-ecu150v2.rootfs.tar.zst
```

---

## Scenario 8 — Yocto rootfs + RAUC + Secure boot

A card flashed from a `SECURE_BOOT_ENABLED = "1"` build. Add **`--secure-boot`**:

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --rauc --secure-boot \
    --yocto imx-image-core-ecu150v2.rootfs.tar.zst
```

---

## Scenario 9 — Yocto rootfs + RAUC + Overlay + Secure boot

Same as Scenario 5, signed: RAUC A/B + overlay, just add `--secure-boot`:

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --rauc --secure-boot \
    --yocto imx-image-core-ecu150v2.rootfs.tar.zst
```

---

## Scenario 10 — Yocto rootfs + Appdata

Plain single rootfs, no RAUC, just an extra partition for application data:

```
p1  ext4  rootfs
p2  ext4  appdata    (empty; for application data)
```

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images "$IMAGES_DIR" \
    --appdata \
    --yocto imx-image-core-ecu150v2.rootfs.tar.zst
```

> [!TIP]
> This partition can be LUKS-encrypted: point `LUKS_DATA_DEVICE = "part:2"` at it (see
> [Application data partition](#application-data-partition---appdata) for how the number
> is derived). The flash tool has no part in this — it only formats a plain ext4
> partition, which `cryptsetup luksFormat` then overwrites on first boot.

---

## Scenario matrix

Note how few flags there are: overlay needs none at flash time (the build decides it),
and secure boot needs exactly one.

| # | Scenario | `--ubuntu` | `--rauc` | `--kernel` | `--appdata` | `--secure-boot` | Partitions |
| --- | --- | :---: | :---: | :---: | :---: | :---: | --- |
| 1 | Ubuntu | yes | | | | | `p1` |
| 2 | Ubuntu + Overlay | yes | | **yes** | | | `p1` |
| 3 | Yocto + Overlay | | | | | | `p1` |
| 4 | Yocto + RAUC | | yes | | | | `p1 p2 p3` |
| 5 | Yocto + RAUC + Overlay | | yes | | | | `p1 p2 p3` |
| 6 | Yocto + **Secure boot** | | | | | **yes** | `p1` |
| 7 | Yocto + Overlay + **Secure boot** | | | | | **yes** | `p1` |
| 8 | Yocto + RAUC + **Secure boot** | | yes | | | **yes** | `p1 p2 p3` |
| 9 | Yocto + RAUC + Overlay + **Secure boot** | | yes | | | **yes** | `p1 p2 p3` |
| 10 | Yocto + **Appdata** | | | | **yes** | | `p1 p2` |

Add `--secure-boot` to **any** row to flash the signed bootloader; add `--appdata` to
any row for an extra data partition. Both are independent of each other and of RAUC —
the build signs the initramfs-bundled kernel via
`meta-ecu-150v2/recipes-secure-boot/linux/linux-imx-signature.bbappend`, so a signed
RAUC bundle keeps secure boot working after an OTA to slot B.

`--yocto <rootfs tarball>` is required in **all** scenarios (it provides the kernel
modules / firmware, and is the rootfs base whenever `--ubuntu` is omitted).

---

## Application data partition (`--appdata`)

`--appdata` adds one more ext4 partition, formatted and labelled `appdata` exactly like
every other one. **Nothing is written to it** — what it becomes is up to whoever owns
it (plain application data, a database, a LUKS container, ...); the flash tool has no
opinion and never mentions any of them. See
[Scenario 10](#scenario-10--yocto-rootfs--appdata) for pairing it with LUKS.

### Partitions are addressed by number, and the number moves

Partitions are laid out in a fixed order, and **the last one always takes the rest of
the disk**:

```
p1     rootfs             (rootfs A with --rauc)
[pN]   rootfs B           --rauc
[pN]   data               --rauc
[pN]   appdata            --appdata          (always last)
```

So `appdata` lands on a different number depending on the flags — but only on
`--rauc`:

| Flags | `appdata` is |
| --- | :---: |
| `--appdata` | `p2` |
| `--rauc --appdata` | `p4` |

> [!IMPORTANT]
> The script prints the number it actually produced at the end of every run — read it
> instead of deriving it, and keep whatever consumes the partition (e.g.
> `LUKS_DATA_DEVICE`) in sync.

> [!CAUTION]
> The `appdata` ext4 label is a flashing-time convenience only. Anything that reformats
> the partition (`mkfs`, `cryptsetup luksFormat`, ...) overwrites the superblock and the
> label disappears — never rely on `/dev/disk/by-label/appdata` to find it later.

---

## Secure boot (HABv4)

Secure boot is an **explicit mode**, chosen with one flag:

| Flag | Bootloader written | Kernel requirement |
| --- | --- | --- |
| `--secure-boot` | `signed-imx-boot-ecu150v2-sd.bin-flash_evk` | `/boot/Image` must end up **signed** — swapped in from `--images` if needed, **refused** if no signed counterpart exists |
| `--no-secure-boot` | `imx-boot-ecu150v2-sd.bin-flash_evk` | `/boot/Image` must end up **unsigned** — swapped in from `--images` if needed, **refused** if no unsigned counterpart exists (no override) |
| *(neither)* | whatever `imx-boot` points at | not enforced; whatever the rootfs ships is reported as-is |

### When `--kernel` is still needed

Only two cases: an **`--ubuntu` base** with no usable `/boot` (Scenario 2), or a
deliberate one-off image. Everywhere else leave it out — it always wins over the
auto-swap, and its own signedness is still checked against an explicit mode (an
unsigned image with `--secure-boot`, or a **signed** image with `--no-secure-boot`, is
refused up front, the latter with no override).


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

- **Secure boot scenarios** — confirm the HAB status. This is a **U-Boot** command, not
  a Linux one: interrupt autoboot and check it at the `=>` prompt **before** Linux
  starts (see [After flashing a signed card](#after-flashing-a-signed-card)):

  ```console
  => hab_status
  No HAB Events Found!
  ```

For overlay internals (development backdoor `overlayroot=disabled`) and the full RAUC
OTA workflow, see the top-level manifest `README.md`.
