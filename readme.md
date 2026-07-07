# Manifest of the Advantech Linux TSU Yocto project
The goal of this project is to release opensource Linux source code that runs on Advantech Hardware

## Download the Yocto Linux for ECU-150v2 and setup environment variables
For downloading the source code and setting up the environment, follow the instructions below:
```console
foo@bar:~/yocto$ repo init -u https://github.com/saurontech/Advantech-ECU-150v2-manifest.git -b main -m ecu150v2-6.12.49-2.2.0.xml
foo@bar:~/yocto$ repo sync
foo@bar:~/yocto$ MACHINE=ecu150v2 DISTRO=fsl-imx-xwayland source ./imx-setup-release.sh -b bld-wayland
foo@bar:~/yocto/bld-wayland$ bitbake-layers add-layer ../sources/meta-ecu-150v2/
```
After the commands, not only was the Yocto project for ECU-150v2 downloaded, the operating console were also setup to operate bitbaker.
Please also notice, that after the commands, your current position has been changed to the build directory!
If, in the future, to operate bitbake from another console; in that spacific console, use the command:
```console
foo@bar:~/yocto$ source ./setup-environment bld-wayland
foo@bar:~/yocto/bld-wayland$
```
## Build Yocto
>[!NOTE]
> On Ubuntu 24.04 hosts, AppAromor settings needs to be adjusted before building Yocto.
>```console
> foo@bar:~/$ sudo sh -c 'echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns'
>```

>[!TIP]
> Edit __local.conf__ based on your host resource.  
> Building Yocto, with the default configure, is very memory consuming. At least 32 GBytes of RAM will be needed.  
> With insufficient RAM, the building process will fail.
> Therefore, limiting the maximum parallel processes allowed, migth be a good idea.
> One may do so by adding the following parameters to **"bld-wayland/config/local.conf"**
> ```sh
> PARALLEL_MAKE = "-j 2"
> BB_NUMBER_THREADS = "2"
> ```

In a console that has been setup properly, use the following command to build Linux and the Yocto rootfs
```console
foo@bar:~/yocto/bld-wayland$ bitbake imx-image-core

```
- The __Linux kernel__ will be located at: __./bld-wayland/tmp/deploy/images/ecu150v2/Image__
- The __dtb__ will be located at: __./bld-wayland/tmp/deploy/images/ecu150v2/imx8mp-evk-ecu150v2.dtb__
- The __rootfs (tar)__ will be located at: __./bld-wayland/tmp/deploy/images/ecu150v2/imx-image-core-ecu150v2.rootfs.tar.zst__
- The __imx-boot (SPL + U-Boot + ATF + OP-TEE)__ will be located at: __./bld-wayland/tmp/deploy/images/ecu150v2/imx-boot-ecu150v2-sd.bin-flash_evk__

To build only the Linux kernel, use the following command instead:
```console
foo@bar:~/yocto/bld-wayland$ bitbake linux-imx
```
## Deploy the Yocto Image
The easiest way to delpy the yocto image is to dump the wic file to a SD card.  
To create a bootable SD card, use the following commands:
> [!CAUTION] 
>  __BEWARE!!!__ The following example assumes that the __SD card__ was located as **/dev/sdb**, change the location accordingly. otherwise, /dev/sdb would be ruined.

> [!NOTE]
>  1. The wic image could be found at `./bld-wayland/tmp/deploy/images/ecu150v2/imx-image-core-ecu150v2.rootfs.wic.zst`
>     A `.bmap` file is also generated alongside it for use with `bmaptool`.
>  2. To deploy the image to the on board EMMC, copy the wic.zst file to the __root/__ partition on the SD, boot from SD and follow the same commands with the following parameters swapped out:
>        1. __/dev/sdb__ swapped to __/dev/mmcblk0__
>        2. __/dev/sdb2__ swapped to __/dev/mmcblk0p2__
>  3. Use the on board hardware switch __SW2__ to select between the boot devices.

```console
foo@bar:~/yocto/bld-wayland/tmp/deploy/images/ecu150v2$ sudo bmaptool copy imx-image-core-ecu150v2.rootfs.wic.zst /dev/sdb
bmaptool: info: 628149 blocks of size 4096 (2.4 GiB), mapped 335669 blocks (1.3 GiB or 53.4%)
bmaptool: info: copying image 'imx-image-core-ecu150v2.rootfs.wic.zst' to block device '/dev/sdb' using bmap file 'imx-image-core-ecu150v2.rootfs.wic.bmap'
bmaptool: info: copying time: 1m 2.0s, copying speed 21.2 MiB/sec
foo@bar:~/yocto/bld-wayland/tmp/deploy/images/ecu150v2$ sudo parted -s -a opt /dev/sdb "resizepart 2 100%"
foo@bar:~/yocto/bld-wayland/tmp/deploy/images/ecu150v2$ sudo e2fsck -f /dev/sdb2
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
root: 27957/280512 files (0.1% non-contiguous), 343501/560564 blocks
foo@bar:~/yocto/bld-wayland/tmp/deploy/images/ecu150v2$ sudo resize2fs /dev/sdb2
resize2fs 1.47.0 (5-Feb-2023)
Resizing the filesystem on /dev/sdb2 to 15292416 (4k) blocks.
The filesystem on /dev/sdb2 is now 15292416 (4k) blocks long.
```

## Create SDK for Yocto
> This section sets up the Yocto cross-compilation SDK on your host (x86) machine.
> It generates a standalone toolchain (compiler, sysroot, kernel headers) targeting the ECU150v2 (armv8a).
> Once installed and sourced, you can compile binaries or out-of-tree kernel modules on the host that run on the target board.
```console
foo@bar:~/yocto/bld-wayland$ bitbake -c populate_sdk core-image-minimal
foo@bar:~/yocto/bld-wayland$ sh ./tmp/deploy/sdk/fsl-imx-xwayland-glibc-x86_64-core-image-minimal-armv8a-ecu150v2-toolchain-6.6-scarthgap.sh
NXP i.MX Release Distro SDK installer version 6.6-scarthgap
===========================================================
Enter target directory for SDK (default: /opt/fsl-imx-xwayland/6.6-scarthgap): ~/my_sdk
You are about to install the SDK to "/home/foo/test/my_sdk". Proceed [Y/n]? y
Extracting SDK...................................................................................................................................................................................................................done
Setting it up...done
SDK has been successfully set up and is ready to be used.
Each time you wish to use the SDK in a new shell session, you need to source the environment setup script e.g.
 $ . /home/foo/my_sdk/environment-setup-armv8a-poky-linux
foo@bar:~/yocto/bld-wayland$ . /home/foo/my_sdk/environment-setup-armv8a-poky-linux
foo@bar:~/yocto/bld-wayland$ make modules_prepare -C $SDKTARGETSYSROOT/usr/src/kernel

```
## Build out-of-tree kernel modules
The following example shows how to build a out-of-tree kernel module with the Yocto SDK.  
We use the Advantech USB-4604B, a USB to serial converter, as an example.  
>[!NOTE]
>Notice that this spacific drivers makefile uses **$(KERNELDIR)** to represent the position of the kernel header files; therefore, we use **export KERNELDIR=$SDKTARGETSYSROOT/usr/src/kernel** before we build the driver with **make**.

```console
foo@bar:~/example$ git clone https://github.com/saurontech/USB-4604-BE-linux-driver.git
foo@bar:~/example$ cd ./USB-4604-BE-linux-driver/driver
foo@bar:~/example/USB-4604-BE-linux-driver/driver$ . /home/foo/my_sdk/environment-setup-armv8a-poky-linux
foo@bar:~/example/USB-4604-BE-linux-driver$ cat ./Makefile
obj-m := adv_usb_serial.o
adv_usb_serial-objs := xr_usb_serial_common.o

KERNELDIR ?= /lib/modules/$(shell uname -r)/bld-wayland
PWD       := $(shell pwd)

EXTRA_CFLAGS	:= -DDEBUG=0

all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD)

modules_install:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules_install

clean:
	rm -rf *.o *~ core .depend .*.cmd *.ko *.mod.c .tmp_versions vtty *.symvers *.order *.a *.mod
foo@bar:~/example/USB-4604-BE-linux-driver/driver$ export KERNELDIR=$SDKTARGETSYSROOT/usr/src/kernel
foo@bar:~/example/USB-4604-BE-linux-driver$ make
```
## Kernel Development
To modify/develop the in-tree kernel source code, the **devtool** command provided by Yocto is a good base to start.
The following command will prepare a kernel source tree, which is managed by git, under **"build/workspace/sources/linux-imx"**.
```console
foo@bar:~/yocto/bld-wayland$ devtool modify linux-imx
foo@bar:~/yocto/bld-wayland$ ls ./workspace/sources/
linux-imx
```
To test the modified source code, build the modified kernel with the following command.
```console
foo@bar:~/yocto/bld-wayland$ devtool build linux-imx
```
To modify the default configure, use the following command.
```console
foo@bar:~/yocto/bld-wayland$ devtool menuconfig  linux-imx
```
During the process, use **"git add, git commit"** to source-control the development.
To save all the changes controlled by git into a new layer, use the following commands
```console
foo@bar:~/yocto/bld-wayland$ bitbake-layers create-layer ../sources/meta-mylayer
foo@bar:~/yocto/bld-wayland$ devtool update-recipe -a ../sources/meta-mylayer linux-imx
```
To finish the process, use the following procedure to clean the current workspace and add the newly created layer to the yocto project.
```console
foo@bar:~/yocto/bld-wayland$ devtool reset linux-imx
foo@bar:~/yocto/bld-wayland$ bitbake-layers add-layer ../sources/meta-mylayer/
foo@bar:~/yocto/bld-wayland$ bitbake linux-imx
```

## Build Debian/Ubuntu based rootfs
follow the instructions below to build the rootfs with debootstrap, qemu, and chroot
```console
foo@bar:~/work$ sudo apt-get install qemu-user-static debootstrap debian-archive-keyring
foo@bar:~/work$ nano ch-rootfs.sh
foo@bar:~/work$ chmod +x ./ch-rootfs.sh
```
the content of ch-rootfs.sh is listed as below:
```sh
#!/bin/bash
#
function mnt() {
 echo "MOUNTING"
 sudo mount -t proc /proc ${2}proc
 sudo mount -t sysfs /sys ${2}sys
 sudo mount -o bind /dev ${2}dev
 sudo mount -o bind /dev/pts ${2}dev/pts
 sudo chroot ${2}
}
function umnt() {
 echo "UNMOUNTING"
 sudo umount ${2}proc
 sudo umount ${2}sys
 sudo umount ${2}dev/pts
 sudo umount ${2}dev
}

function pack() {
 echo "Packing rootfs to rootfs.tar.gz ...."
 sudo rm -f ../rootfs.tar.gz
 echo '=== tar rootfs start ==='
 cd $2 && sudo tar zcvf ../rootfs.tar.gz *
 echo '=== tar rootfs finish ==='
}

if [ "$1" == "-m" ] && [ -n "$2" ] ;
then
 mnt $1 $2
 umnt $1 $2
elif [ "$1" == "-u" ] && [ -n "$2" ];
then
 umnt $1 $2
elif [ "$1" == "-z" ] && [ -n "$2" ];
then
 pack $1 $2
else
 echo ""
 echo "Either 1'st, 2'nd or both parameters were missing"
 echo ""
 echo "1'st parameter can be one of these: -m(mount) OR -u(umount) or -z(pack)"
 echo "2'nd parameter is the full path of rootfs directory(with trailing '/')"
 echo ""
 echo "For example: ./ch-rootfs.sh -m /media/sdcard/"
 echo ""
 echo 1st parameter : ${1}
 echo 2nd parameter : ${2}
fi

```
> [!NOTE]
> The following commands will slightly differe between Debian 12 and Ubuntu 24.04; therefore, we seperate the instuctions into two subsections.  
> Choose the instructions based on your target distro.
> The "deb" files mentioned below could be found in "yocto/build/tmp/deploy/deb/all/".
### Debian 12 
```console
foo@bar:~/work$ sudo debootstrap --arch arm64 bookworm my_rootfs http://deb.debian.org/debian
foo@bar:~/work$ sudo tar xvf ./modules-ecu150v2.tgz -C ./my_rootfs/usr/
foo@bar:~/work$ cp firmware-imx-sdma-imx7d*.deb ./my_rootfs/tmp/
foo@bar:~/work$ cp linux-firmware-rtl*.deb ./my_rootfs/tmp/
foo@bar:~/work$ cp linux-firmware-whence-license_*.deb ./my_rootfs/tmp/
foo@bar:~/work$ ./ch-rootfs.sh -m ./my_rootfs/
root@imx:~/$ apt-get update
root@imx:~/$ apt-get install sudo ssh net-tools iputils-ping rsyslog bash-completion htop resolvconf dialog gpiod vim locales netplan.io systemd-timesyncd systemd-resolved
root@imx:~/$ dpkg-reconfigure locales
root@imx:~/$ cd /tmp  && dpkg -i *.deb
root@imx:~/$ rm /tmp/*
```
### Ubuntu 24.04
```console
foo@bar:~/work$ sudo debootstrap --arch arm64 noble my_rootfs http://tw.archive.ubuntu.com/ubuntu/
foo@bar:~/work$ sudo tar xvf ./modules-ecu150v2.tgz -C ./my_rootfs/usr/
foo@bar:~/work$ cp firmware-imx-sdma-imx7d*.deb ./my_rootfs/tmp/
foo@bar:~/work$ cp linux-firmware-rtl*.deb ./my_rootfs/tmp/
foo@bar:~/work$ cp linux-firmware-whence-license_*.deb ./my_rootfs/tmp/
foo@bar:~/work$ ./ch-rootfs.sh -m ./my_rootfs/
root@imx:~/$ apt-get update
root@imx:~/$ add-apt-repository universe
root@imx:~/$ apt install sudo ssh net-tools iputils-ping rsyslog bash-completion htop vim nano netplan.io software-properties-common gpiod
root@imx:~/$ cd /tmp  && dpkg -i *.deb
root@imx:~/$ rm /tmp/*
```
On Ubuntu, root login is disabled by default; therefore it is a good idea to add a user with sudo privilage.
```console
root@imx:~/$ adduser admin
root@imx:~/$ usermod -aG sudo admin
```
> [!NOTE]
> The difference between Debian 12/Ubuntu 24.04 stops here.  
The following instructions can be shared between two target distros.
```console
root@imx:~/$ ln -s /dev/null /etc/systemd/network/99-default.link
root@imx:~/$ echo 'ecu150v2' > /etc/hostname
root@imx:~/$ cat <<EOF >> /etc/udev/rules.d/localextra.rules
# Microchip Technology USB2740 Hub
KERNEL=="rtc0", SYMLINK+="rtc"    # External RTC is exposed as /dev/rtc0

KERNEL=="ttymxc2", GROUP="dialout", MODE="0664", SYMLINK+="ttyAP0"
KERNEL=="ttymxc3", GROUP="dialout", MODE="0664", SYMLINK+="ttyAP1"
EOF
root@imx:~/$ systemctl enable systemd-networkd.service
root@imx:~/$ systemctl enable systemd-resolved.service
root@imx:~/$ systemctl enable systemd-timesyncd.service
root@imx:~/$ nano /etc/profile.d/custom.sh
root@imx:~/$ exit
foo@bar:~/work$ ./ch-rootfs.sh -z ./my_rootfs/
```
The constent of custom.sh is listed as below:
```sh
# Set the prompt for bash and ash (no other shells known to be in use here)
[ -z "$PS1" ] || PS1='\u@\h:\w\$ '

# Use the EDITOR not being set as a trigger to call resize later on
FIRSTTIMESETUP=0
if [ -z "$EDITOR" ] ; then
    FIRSTTIMESETUP=1
fi

if [ -t 0 -a $# -eq 0 ]; then
    if [ ! -x /usr/bin/resize ] ; then
        if [ -n "$BASH_VERSION" ] ; then
            # Optimized resize funciton for bash
resize() {
    local x y
    IFS='[;' read -t 2 -p $(printf '\e7\e[r\e[999;999H\e[6n\e8') -sd R _ y x _
    [ -n "$y" ] && \
    echo -e "COLUMNS=$x;\nLINES=$y;\nexport COLUMNS LINES;" && \
    stty cols $x rows $y
}
        else
# Portable resize function for ash/bash/dash/ksh
# with subshell to avoid local variables
resize() {
    (o=$(stty -g)
    stty -echo raw min 0 time 2
    printf '\0337\033[r\033[999;999H\033[6n\0338'
    if echo R | read -d R x 2> /dev/null; then
        IFS='[;R' read -t 2 -d R -r z y x _
    else
        IFS='[;R' read -r _ y x _
    fi
    stty "$o"
    [ -z "$y" ] && y=${z##*[}&&x=${y##*;}&&y=${y%%;*}
    [ -n "$y" ] && \
    echo "COLUMNS=$x;"&&echo "LINES=$y;"&&echo "export COLUMNS LINES;"&& \
    stty cols $x rows $y)
}
        fi
    fi
    # only do this for /dev/tty[A-z] which are typically
    # serial ports
    if [ $FIRSTTIMESETUP -eq 1 -a ${SHLVL:-1} -eq 1 ] ; then
        case $(tty 2>/dev/null) in
            /dev/tty[A-z]*) resize >/dev/null;;
        esac
    fi
fi

```

## RAUC OTA (A/B update)

`meta-ecu150v2` includes built-in RAUC A/B OTA support. All RAUC-related variables are centralized in `conf/include/ecu150v2-rauc.inc`. A single toggle in `local.conf`, combined with a one-time key generation, is all that is needed to build and deploy OTA bundles.

### 1. Enable / Disable RAUC

Edit `bld-wayland/conf/local.conf`:

```sh
# Enable RAUC OTA (default: disabled)
RAUC_ENABLED = "1"
```

Set to `"0"` to remove the `rauc` binary, `libubootenv-bin`, and all A/B boot policy configuration from the image, reverting to single-rootfs behavior.

### 2. One-time: Generate signing keys (**never store inside the layer**)

Keys are kept outside the layer at `${HOME}/.config/rauc-keys-ecu150v2/` to prevent accidental commits or leaks via `rsync`.

```console
foo@bar:~$ export KEYS=${HOME}/.config/rauc-keys-ecu150v2
foo@bar:~$ mkdir -p ${KEYS} && chmod 700 ${KEYS}
foo@bar:~$ cd ${KEYS} && bash <yocto>/sources/meta-rauc/scripts/openssl-ca.sh
foo@bar:~/.config/rauc-keys-ecu150v2$ cp openssl-ca/dev/ca.cert.pem                    ca.cert.pem
foo@bar:~/.config/rauc-keys-ecu150v2$ cp openssl-ca/dev/development-1.cert.pem         dev.cert.pem
foo@bar:~/.config/rauc-keys-ecu150v2$ cp openssl-ca/dev/private/development-1.key.pem  dev.key.pem
foo@bar:~/.config/rauc-keys-ecu150v2$ chmod 600 *.key.pem
foo@bar:~/.config/rauc-keys-ecu150v2$ cp ca.cert.pem <yocto>/sources/meta-ecu150v2/recipes-core/rauc/files/ca.cert.pem
```

> The bundle recipe defaults to `${HOME}/.config/rauc-keys-ecu150v2/` via `?=`. To use a different path (CI / HSM), override `RAUC_KEYS_DIR = "..."` in `local.conf`.

### 3. Build the A/B image and bundle

```console
foo@bar:~/yocto/bld-wayland$ bitbake imx-image-core      # includes rauc, libubootenv-bin, A/B config
foo@bar:~/yocto/bld-wayland$ bitbake update-bundle       # produces the signed .raucb bundle
```

Build artifacts:
- rootfs tarball: `tmp/deploy/images/ecu150v2/imx-image-core-ecu150v2.rootfs.tar.zst`
- imx-boot binary: `tmp/deploy/images/ecu150v2/imx-boot-ecu150v2-sd.bin-flash_evk`
- OTA bundle: `tmp/deploy/images/ecu150v2/update-bundle-ecu150v2.raucb`

> [!IMPORTANT]
> The default `*.wic.zst` produced by `imx-image-core` is a **single-rootfs** layout and is **not** compatible with RAUC A/B. To produce the required `p1=rootfs A` / `p2=rootfs B` / `p3=/data` layout on SD or eMMC, use `tools/flash/ecu150v2_flash.sh` (located in the manifest repo) instead of `bmaptool`. The script consumes the rootfs tarball and `imx-boot` binary listed above.

Verify bundle signature on the build host:

```console
foo@bar:~$ rauc info --keyring=${KEYS}/ca.cert.pem \
    tmp/deploy/images/ecu150v2/update-bundle-ecu150v2.raucb
```

### 4. Flash the A/B layout to SD / eMMC

> [!NOTE]
> The examples below use an **SD card** as the boot medium. On ECU-150v2, the on-board eMMC
> is always `mmcblk0` and the SD card slot is always `mmcblk1`. All `mmcblk1pN` references
> below assume booting from SD. If flashing to eMMC instead, substitute `mmcblk1` with
> `mmcblk0` throughout.

`tools/flash/ecu150v2_flash.sh` (in the manifest repo) creates p1 `rootfs.0` / p2 `rootfs.1` / p3 `data` (all ext4) and writes `imx-boot` at the 32 KiB offset. Slot A is populated with the rootfs tarball; slot B is left empty for the first OTA install.

```console
sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images bld-wayland/tmp/deploy/images/ecu150v2 \
    --rauc \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
```

> Replace `/dev/sdX` with the actual target device (`/dev/sdb` for SD, `/dev/mmcblk0` on the target for eMMC). Double-check the device — the script wipes the entire disk.
>
> To also populate slot B (useful for rollback bench-testing), append `--populate-b`.

> [!NOTE]
> For other flash layout combinations (Ubuntu base, RAUC A/B, Ubuntu + Overlay, etc.),
> see [`tools/flash/README.md`](tools/flash/README.md).

Boot the target from this medium once and confirm A/B is set up correctly:

```console
root@ecu150v2:~$ lsblk                             # expect mmcblk1p1/p2/p3
root@ecu150v2:~$ findmnt /                         # expect /dev/mmcblk1p1
root@ecu150v2:~$ mountpoint /data                  # expect: /data is a mountpoint
root@ecu150v2:~$ rauc status                       # booted from rootfs.0, slot B empty
```

### 5. OTA install on target

Copy the bundle to the target, then install it:

```console
foo@bar:~$ scp update-bundle-ecu150v2.raucb root@<target>:/tmp/
```

```console
root@ecu150v2:~$ rauc status                       # confirm current slot (e.g. booted from rootfs.0 / A)
root@ecu150v2:~$ rauc install /tmp/update-bundle-ecu150v2.raucb
root@ecu150v2:~$ fw_printenv BOOT_ORDER            # expect "B A"
root@ecu150v2:~$ reboot
```

After reboot, the U-Boot console should print `RAUC: trying slot B (root=p2)`. Once Linux is up:

```console
root@ecu150v2:~$ findmnt /                         # expect /dev/mmcblk1p2
root@ecu150v2:~$ rauc status                       # booted from rootfs.1
```

### 6. Identifying bundle versions

The bundle recipe defaults to `RAUC_BUNDLE_VERSION = "${DATETIME}"`. After installation, `rauc status` displays the `bundle-version` per slot. To embed additional metadata (e.g. git hash, build ID), edit `meta-ecu150v2/recipes-core/bundles/update-bundle.bb`.


## Immutable OS (overlayfs via initramfs)

`meta-ecu150v2` includes optional OverlayFS-root support. When enabled, the real rootfs is mounted **read-only** as the overlay lower layer, and all writes defaultly land on a volatile tmpfs (wiped on reboot).

It is implemented with a standard **initramfs + switch_root** flow: an `overlay-init` script (PID 1) mounts the read-only rootfs, stacks an overlayfs on top, then hands off to the real `/sbin/init`. The initramfs is bundled into the kernel `Image` (CPIO fromat), so U-Boot keeps using the same `booti ${loadaddr} - ${fdt_addr}` command.

All overlay-related variables are centralized in `conf/include/ecu150v2-overlay.inc`. A single toggle in `local.conf` is all that is needed.

### 1. Enable / Disable OverlayFS root

Edit `bld-wayland/conf/local.conf`:

```sh
# Enable OverlayFS root via initramfs (default: disabled)
OVERLAY_INITRAMFS_ROOT = "1"
```

This single switch does two things automatically:
- Bundles the `initramfs-overlay-image` (which provides `/init`) into the kernel image (`INITRAMFS_IMAGE_BUNDLE = "1"`).
- During image assembly, overwrites the rootfs `/boot/Image` with the initramfs-bundled kernel, so the kernel U-Boot loads from the rootfs actually contains the overlay `/init`.

### 2. Build

```console
foo@bar:~/yocto/bld-wayland$ bitbake imx-image-core
```

> [!TIP]
> If you only changed `OVERLAY_INITRAMFS_ROOT`, a clean rebuild of the kernel and image
> ensures the bundled kernel is regenerated and copied into the rootfs:
> ```console
> foo@bar:~/yocto/bld-wayland$ bitbake virtual/kernel -c cleansstate
> foo@bar:~/yocto/bld-wayland$ bitbake imx-image-core
> ```

After building with `OVERLAY_INITRAMFS_ROOT = "1"`, the kernel inside the rootfs
is the initramfs-bundled version. Note that **no artifact paths change** —
you still flash the same `imx-image-core-ecu150v2.rootfs.tar.zst`, but its
`/boot/Image` is now the ~46 MB bundled kernel instead of the ~34 MB bare one:

- Bundled kernel (intermediate, auto-installed into rootfs):
  `tmp/deploy/images/ecu150v2/Image-initramfs-ecu150v2.bin`
- The rootfs you actually flash (unchanged path):
  `tmp/deploy/images/ecu150v2/imx-image-core-ecu150v2.rootfs.tar.zst`

### 3. Verify the bundled kernel before flashing

Confirm the rootfs `/boot/Image` is the larger, initramfs-bundled kernel (not the bare one):

```console
foo@bar:~/yocto/bld-wayland$ binwalk tmp/work/ecu150v2-poky-linux/imx-image-core/*/rootfs/boot/Image | grep -i cpio
# expect to find a cpio archive containing 'init' and 'bin/busybox'
```

### 4. Flash and boot

Flash the SD/eMMC with `tools/flash/ecu150v2_flash.sh`, pointing `--kernel` at the
initramfs-bundled kernel — this is what makes the overlay `/init` take over at boot.
The script writes `imx-boot` at the 32 KiB offset, creates the rootfs partition, and
installs the kernel as `/boot/Image`:

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images bld-wayland/tmp/deploy/images/ecu150v2 \
    --kernel Image-initramfs-ecu150v2.bin \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
```

The kernel runs `/init` (the overlay script) in initramfs instead of `/sbin/init` in real rootfs automatically,
because the initramfs is embedded in the Image — the boot command itself is unchanged.
By default, overlay writes land on a volatile tmpfs and are wiped on every reboot.

> [!NOTE]
> For other flash layout combinations (Ubuntu base, RAUC A/B, Ubuntu + Overlay, etc.),
> see [`tools/flash/README.md`](tools/flash/README.md).

### 5. Verify on the target

After boot, confirm the overlay is active:

```console
root@ecu150v2:~$ mount | grep overlay
# overlay on / type overlay (rw,...,lowerdir=...,upperdir=/run/rwdata/single/upper,...)

root@ecu150v2:~$ mount | grep ' /ro '
# /dev/mmcblk1pN on /ro type ext4 (ro,relatime)    <-- real rootfs, read-only

root@ecu150v2:~$ df -h /rw
# tmpfs mounted at /rw — this is where writes actually land
```

Confirm writes are volatile (the key property — they vanish on reboot):

```console
root@ecu150v2:~$ echo test > /overlay_write_test && reboot
# after reboot:
root@ecu150v2:~$ ls /overlay_write_test
# ls: cannot access '/overlay_write_test': No such file or directory
```

The boot log should also show the overlay-init taking over:

```text
Run /init as init process
overlay-init: lower (read-only rootfs): /dev/mmcblk1pN (ext4)
overlay-init: writable slot: single
overlay-init: switching to overlay root, real init: /sbin/init
```

### 6. Development backdoor

To temporarily boot with a normal read-write rootfs (e.g. to modify the rootfs in place
during development) **without** rebuilding, interrupt U-Boot and append `overlayroot=disabled`
to the kernel command line. The `overlay-init` script will skip the overlay and mount the
real rootfs read-write.

> [!NOTE]
> This is a development convenience only. Production images should always boot with the
> overlay active so the rootfs stays immutable and power-loss-safe.

