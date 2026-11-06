# Manifest of the Advantech Linux TSU Yocto project
The goal of this project is to release opensource Linux source code that runs on Advantech Hardware

>[!IMPORTANT]
> **This is the `walnascar-cip` branch: ECU-150v2 on Yocto walnascar with the CIP kernel patches.**
>
> CIP (Civil Infrastructure Platform) is a Linux Foundation project that maintains selected
> kernel series as Super Long Term Support (SLTS) kernels. 6.12 is one of them, published as
> `v6.12.<sublevel>-cip<N>` tags. This branch keeps the NXP BSP and adds the CIP patches on
> top of the NXP kernel, so the product kernel follows the CIP 6.12 SLTS updates.
>
> | Item | This branch (`walnascar-cip`) |
> |---|---|
> | Yocto release | walnascar (5.2) |
> | NXP BSP | `rel_imx_6.12.49_2.2.0` (the manifest file name `ecu150v2-6.12.49-2.2.0.xml` refers to this BSP release) |
>
> For the NXP 6.12.49 kernel without the CIP patches, use the `main` branch of this manifest.

## Download the Yocto Linux for ECU-150v2 and setup environment variables
For downloading the source code and setting up the environment, follow the instructions below:
```console
foo@bar:~/yocto$ repo init -u https://github.com/saurontech/Advantech-ECU-150v2-manifest.git -b walnascar-cip -m ecu150v2-6.12.49-2.2.0.xml
foo@bar:~/yocto$ repo sync
foo@bar:~/yocto$ MACHINE=ecu150v2 DISTRO=fsl-imx-xwayland source ./imx-setup-release.sh -b bld-wayland
foo@bar:~/yocto/bld-wayland$ ../sources/meta-ecu-150v2/scripts/ecu150v2-setup.sh
```
After the commands, not only was the Yocto project for ECU-150v2 downloaded, the operating console were also setup to operate bitbaker.
Please also notice, that after the commands, your current position has been changed to the build directory!

>[!IMPORTANT]
> `ecu150v2-setup.sh` replaces the older single `bitbake-layers add-layer ../sources/meta-ecu-150v2/` step.
> It adds **all** layers this product needs, in one idempotent command:
> - `meta-ecu-150v2` — the product layer itself
> - `meta-rauc` — required by the RAUC A/B OTA integration
> - `meta-nxp-security-reference-design/meta-secure-boot` — **not optional**: `meta-ecu-150v2`
>   carries a `linux-imx-signature` bbappend, and a bbappend whose target recipe is missing
>   makes bitbake fail outright, even with `SECURE_BOOT_ENABLED = "0"`.
>
> **Re-run it after every `imx-setup-release.sh`.** That script restores
> `conf/bblayers.conf` from `conf/bblayers.conf.org` and then appends only NXP's own
> layers, so anything added by hand is silently dropped. Re-running `ecu150v2-setup.sh`
> is harmless — each layer is added only when absent.

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

`meta-ecu-150v2` includes built-in RAUC A/B OTA support. All RAUC-related variables are centralized in `conf/include/ecu150v2-rauc.inc`. A single toggle in `local.conf`, combined with a one-time key generation, is all that is needed to build and deploy OTA bundles.

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
foo@bar:~/.config/rauc-keys-ecu150v2$ cp ca.cert.pem <yocto>/sources/meta-ecu-150v2/recipes-core/rauc/files/ca.cert.pem
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

The bundle recipe defaults to `RAUC_BUNDLE_VERSION = "${DATETIME}"`. After installation, `rauc status` displays the `bundle-version` per slot. To embed additional metadata (e.g. git hash, build ID), edit `meta-ecu-150v2/recipes-core/bundles/update-bundle.bb`.

---

## RAUC Adaptive Update (delta OTA via HTTP streaming)

Adaptive update is an optional extension on top of the standard A/B OTA. When enabled, RAUC compares the incoming bundle against the **currently installed slot** and only transfers the changed 4 KiB blocks over the network — significantly reducing bandwidth and install time for incremental updates.

### Prerequisites

- `RAUC_ENABLED = "1"` must already be set (adaptive is an extension of the base RAUC feature).
- The HTTP server serving the bundle **must support Range Requests** (responds with HTTP `206`). Use nginx — it supports Range Requests out of the box and is the only tested server for this workflow.
- RAUC ≥ 1.6 on the target (walnascar ships a compatible version).

### 1. Enable adaptive update

Edit `bld-wayland/conf/local.conf`:

```sh
# Enable RAUC OTA (required base)
RAUC_ENABLED = "1"

# Enable adaptive delta update (default: disabled)
RAUC_ADAPTIVE_ENABLED = "1"
```

### 2. Build the adaptive bundle

No changes to the build commands — the toggle is fully transparent:

```console
foo@bar:~/yocto/bld-wayland$ bitbake imx-image-core
foo@bar:~/yocto/bld-wayland$ bitbake update-bundle
```

Verify the bundle contains the adaptive metadata (`${KEYS}` — see RAUC OTA step 2):

```console
foo@bar:~$ rauc info --keyring=${KEYS}/ca.cert.pem \
    tmp/deploy/images/ecu150v2/update-bundle-ecu150v2.raucb
```

### 3. Serve the bundle over HTTP

The bundle must be served by an HTTP server that supports Range Requests. The recommended approach is nginx:

```console
foo@bar:~$ sudo apt-get install -y nginx
foo@bar:~$ sudo tee /etc/nginx/sites-available/rauc-bundle <<'EOF'
server {
    listen 8080;
    root /path/to/bld-wayland/tmp/deploy/images/ecu150v2;
    location / { sendfile off; autoindex on; }
}
EOF
foo@bar:~$ sudo ln -sf /etc/nginx/sites-available/rauc-bundle \
               /etc/nginx/sites-enabled/rauc-bundle
foo@bar:~$ sudo rm -f /etc/nginx/sites-enabled/default
foo@bar:~$ sudo nginx -t && sudo systemctl restart nginx
```

### 4. Install via streaming on target

Replace `<server-ip>` with the build host's IP address. The `:8080` port must match the `listen` directive in the nginx config above.

```console
root@ecu150v2:~$ rauc status                       # confirm current slot before install
root@ecu150v2:~$ rauc install http://<server-ip>:8080/update-bundle-ecu150v2.raucb
...
98% Copying image to rootfs.0
99% Copying image to rootfs.0
99% Copying image to rootfs.0 done.
99% Updating slots done.
100% Installing done.
idle
Installing `http://<server-ip>:8080/update-bundle-ecu150v2.raucb` succeeded
root@ecu150v2:~$ fw_printenv BOOT_ORDER            # expect "B A" (or "A B" if installing to A)
root@ecu150v2:~$ reboot
```

After reboot, confirm the new slot is active:

```console
root@ecu150v2:~$ rauc status                       # booted from the newly installed slot
```

### 5. Verify delta transfer (optional)

On the build host, inspect the nginx access log while the install is in progress. A successful adaptive install produces many `206` lines — one per fetched block range — rather than a single large `200` transfer:

```console
foo@bar:~$ tail -f /var/log/nginx/access.log
# expect lines like:  "GET /update-bundle-ecu150v2.raucb HTTP/1.1" 206 4096
```

On the target, run with `--debug` to see the reused / fetched block counts reported by RAUC:

```console
root@ecu150v2:~$ rauc --debug install http://<server-ip>:8080/update-bundle-ecu150v2.raucb \
    2>&1 | tee /tmp/rauc-adaptive.log
```

---

## Immutable OS (overlayfs via initramfs)

`meta-ecu-150v2` includes optional OverlayFS-root support. When enabled, the real rootfs is mounted **read-only** as the overlay lower layer, and all writes defaultly land on a volatile tmpfs (wiped on reboot).

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

## Secure Boot (HABv4)

`meta-ecu-150v2` includes built-in HABv4 secure boot: one switch signs both the
bootloader and the kernel. Variables are centralized in `conf/include/ecu150v2-secure-boot.inc`.

### 1. Make sure the required layer is present

`meta-secure-boot` is a **hard prerequisite** (`meta-ecu-150v2` carries a bbappend
targeting it; without the layer, bitbake fails outright). It is already added by the
setup step at the top of this document — re-run it after every `imx-setup-release.sh`
(that script resets `bblayers.conf` on each run):

```console
foo@bar:~/yocto/bld-wayland$ ../sources/meta-ecu-150v2/scripts/ecu150v2-setup.sh
```

### 2. One-time: generate signing keys (**never store inside the layer**)

Two directories are involved, and they are deliberately kept separate:

| Variable | Default | Contents |
|---|---|---|
| `SIG_TOOL_PATH` | `${HOME}/.config/cst` | the NXP CST tool — public, shareable, replaceable |
| `SIG_DATA_PATH` | `${HOME}/.config/hab-keys-ecu150v2` | **your** `keys/`, `crts/` and `csf_hab4.cfg` — secret, per-product, irreplaceable |

**a) Install CST and generate the PKI tree**

```console
foo@bar:~$ tar xf <NXP's IMX_CST_TOOL>.tgz -C ~/tools/
foo@bar:~$ ln -s ~/tools/cst-3.4.1 ${HOME}/.config/cst
foo@bar:~$ cd ${HOME}/.config/cst/keys
foo@bar:~/.config/cst/keys$ echo "12345678" > serial              # certificate serial seed
foo@bar:~/.config/cst/keys$ printf "my_pass\nmy_pass\n" > key_pass.txt   # private key password, twice
foo@bar:~/.config/cst/keys$ ./hab4_pki_tree.sh                    # interactive
```

**b) Generate the SRK table and the eFuse hash**

```console
foo@bar:~$ cd ${HOME}/.config/cst/crts
foo@bar:~/.config/cst/crts$ ../linux64/bin/srktool -h 4 -d sha256 -f 1 \
    -t SRK_1_2_3_4_table.bin -e SRK_1_2_3_4_fuse.bin \
    -c ./SRK1_sha256_2048_65537_v3_ca_crt.pem,./SRK2_sha256_2048_65537_v3_ca_crt.pem,./SRK3_sha256_2048_65537_v3_ca_crt.pem,./SRK4_sha256_2048_65537_v3_ca_crt.pem
```

> No space after the commas in `-c` (UG10106 4.1.3). `SRK_1_2_3_4_fuse.bin` holds the
> hash you will burn into the eFuses in step 6.

**c) Copy the keys into this product's key directory**

```console
foo@bar:~$ export KEYS=${HOME}/.config/hab-keys-ecu150v2
foo@bar:~$ mkdir -p ${KEYS} && chmod 700 ${KEYS}
foo@bar:~$ cp -r ${HOME}/.config/cst/keys ${HOME}/.config/cst/crts ${KEYS}/
```

**d) `csf_hab4.cfg` — not needed to get started, but required before you close a device**

This file answers *"which key signs the image"*. You do **not** have to write it to get a
signed build going: if `${SIG_DATA_PATH}/csf_hab4.cfg` (and `csf_hab4_pkcs11.cfg`) are
absent, `imx-boot-signature.bb` automatically uses NXP's bundled
`csf_hab4.cfg.sample`, which already points at the standard CST certificate names. So for
bring-up and `hab_status` testing you can skip this step entirely.

The catch is the `Unlock` section. The sample declares it but leaves it **empty**:

```ini
#Unlock
unlock_engine=
unlock_features=
unlock_uid=
```

On i.MX8MP those two blanks must become `CAAM` / `MID` (see the CAUTION below), and that
only matters at the moment you **close the device** — which is irreversible. Hence the
two workable orders of work:

| When | What to do |
|---|---|
| While testing (device still open) | Do nothing. Let the build use the sample; verify `hab_status` reports no events. |
| **Before closing the device** | Supply your own `csf_hab4.cfg` with the `Unlock` fields filled in, rebuild, reflash, re-verify — *then* burn fuses and close. |

To supply your own copy, start from the sample **that your own build produced**. Do not
download it from GitHub: `nxp-imx-signer.bb` pins `SRCREV`, so the file on the upstream
`master` branch can drift away from the one your signer actually understands.

```console
foo@bar:~$ export KEYS=${HOME}/.config/hab-keys-ecu150v2
foo@bar:~/yocto/bld-wayland$ cp tmp/deploy/images/ecu150v2/imx-boot-tools/csf_hab4.cfg.sample \
    ${KEYS}/csf_hab4.cfg
```

> That copy is deployed by `nxp-imx-signer.bb`, so it appears once you have built at least
> once — which you will have done already, since this step comes after bring-up testing.
> On a tree that has never been built, unpack just that recipe to get the same file at
> `tmp/work/x86_64-linux/nxp-imx-signer-native/*/git/csf_hab4.cfg.sample`:
>
> ```console
> foo@bar:~/yocto/bld-wayland$ bitbake -c unpack nxp-imx-signer-native
> ```

Then edit the copy:

**1. Fill in the `Unlock` fields:**

```diff
 #Unlock
-unlock_engine=
-unlock_features=
+unlock_engine=CAAM
+unlock_features=MID
 unlock_uid=
```

**2. Make the certificate names match your own PKI.** Compare against `ls ${KEYS}/crts/`
and adjust `srktable_file`, `csfk_file` and `img_file` if your CST run produced different
names (a key type or length other than `sha256_2048_65537_v3` changes them). Leave
`unlock_uid=` and `nocak_file=` empty — they must still be present.

> [!NOTE]
> **Bare file names only — never prefix with `crts/`.** The signer already hardcodes the
> directory (`<SIG_DATA_PATH>/crts/<name>` for certificates, `<SIG_DATA_PATH>/keys/<name>`
> for private keys). A `crts/` prefix resolves to `crts/crts/` and fails.

### 3. Enable / Disable

Edit `bld-wayland/conf/local.conf`:

```sh
# Enable HABv4 secure boot (default: disabled)
SECURE_BOOT_ENABLED = "1"

# Only needed when deviating from the directory convention in step 2:
#SIG_TOOL_PATH = "/path/to/cst-3.4.1"
#SIG_DATA_PATH = "/path/to/product-keys"
```

Set to `"0"` (or omit the line) to go back to an unsigned build: the signing
`MACHINE_FEATURES` are removed, `imx-boot` and the kernel are deployed unsigned, and none
of the key directories are touched. The build target stays `imx-image-core` either way.

> [!TIP]
> With `SECURE_BOOT_ENABLED = "1"`, `SIG_TOOL_PATH` and `SIG_DATA_PATH` are validated at
> parse time, so a missing CST or key directory stops the build early. Note that the
> presence of `csf_hab4.cfg` is deliberately **not** checked — blocking it would also
> break PKCS#11 / HSM setups, which legitimately use `csf_hab4_pkcs11.cfg` instead. Getting
> that file right is on you (step 2d).

### 4. Build

```console
foo@bar:~/yocto/bld-wayland$ bitbake imx-image-core
```

### 5. Flash

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images bld-wayland/tmp/deploy/images/ecu150v2 \
    --secure-boot \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
```

> [!NOTE]
> Add `--rauc` / `--overlay-data` as needed — see [`tools/flash/README.md`](tools/flash/README.md).

### 6. Verify before burning fuses

Boot the signed image and interrupt autoboot. While the device is still **open**, HAB
already processes the CSF and reports any problem it found — so this is your only chance
to catch a bad signature without consequences:

```console
=> hab_status

Secure boot disabled

HAB Configuration: 0xf0, HAB State: 0x66
No HAB Events Found!
```

> [!CAUTION]
> Everything from here on is **irreversible**. eFuses are one-way: a wrong SRK hash or a
> premature close leaves you with a board that will only accept images signed by a PKI you
> may no longer have. Do steps 7–9 on a sacrificial board first.

### 7. Burn `SRK_HASH` (device still open)

Read the eight 32-bit words out of the fuse binary produced in step 2b:

```console
foo@bar:~$ hexdump -e '/4 "0x"' -e '/4 "%X""\n"' \
    ${HOME}/.config/hab-keys-ecu150v2/crts/SRK_1_2_3_4_fuse.bin
0x9A842534
0xB0491AB4
0xD5B6A07B
0xFD92DCE7
0xC10DC87C
0xD8BD04A9
0x704E9FE4
0x9B025359
```

On i.MX8MP the SRK hash lives in fuse **bank 6 (words 0–3)** and **bank 7 (words 0–3)**,
in that order. Substitute your own values — the ones below are an example:

```console
=> fuse prog -y 6 0 0x9A842534
=> fuse prog -y 6 1 0xB0491AB4
=> fuse prog -y 6 2 0xD5B6A07B
=> fuse prog -y 6 3 0xFD92DCE7
=> fuse prog -y 7 0 0xC10DC87C
=> fuse prog -y 7 1 0xD8BD04A9
=> fuse prog -y 7 2 0x704E9FE4
=> fuse prog -y 7 3 0x9B025359
```

> The bank/word layout above is not ECU-150v2 specific — it is the standard i.MX8M family
> mapping documented by NXP in the U-Boot HABv4 guide, §1.7 "Programming SRK Hash":
> <https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/habv4/guides/mx8m_secure_boot.txt>
> (This manifest, so far, uses u-boot-imx v2025.04, and the guide should be stable across releases).

Read them back and confirm they match exactly:

```console
=> fuse read 6 0 4
=> fuse read 7 0 4
```

Then **reboot and run `hab_status` again**. It must still report `No HAB Events Found!`.
This second check is not redundant: from HAB 4.1.2 onwards, a non-zero SRK fuse makes HAB
actually compare the SRK table in your image against the burnt hash even while the device
is open. A mismatch shows up here — the last point at which it is still recoverable.

### 8. Close the device

Before running the command below, confirm all of the following:

- `hab_status` reports `No HAB Events Found!` **after** the SRK hash was burnt (step 7)
- The image on the board is the signed one
- You still have the PKI (`keys/`, `crts/`) backed up somewhere safe — without it you
  can never sign another image for this board

Closing is done by programming the `SEC_CONFIG[1]` fuse (bank 1, word 3, bit 25):

```console
=> fuse prog 1 3 0x2000000
```

> Source: U-Boot HABv4 guide §1.9 "Closing the device"
> (<https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/habv4/guides/mx8m_secure_boot.txt>).
> (This manifest, so far, uses u-boot-imx v2025.04, and the guide should be stable across releases).

Reboot and confirm the device is now closed:

```console
=> hab_status

Secure boot enabled

HAB Configuration: 0xcc, HAB State: 0x99
No HAB Events Found!
```

## LUKS + TPM (encrypted `/data` or `/appdata`)

`meta-ecu-150v2` includes optional LUKS2 encryption for a data partition, unlocked
automatically at boot by the on-board TPM. All variables are centralized in
`conf/include/ecu150v2-luks.inc`.

### 1. Enable / Disable

Edit bld-wayland/conf/local.conf:

```sh
# Enable LUKS encryption (default: disabled)
LUKS_DATA_ENABLED  = "1"
# Which partition to encrypt -- NO DEFAULT
LUKS_DATA_DEVICE = "part:N"
# The default mountpoint for the decrypted partition (default: /appdata)
LUKS_DATA_MOUNT  = "/appdata"
```

> [!IMPORTANT]
> If `LUKS_DATA_DEVICE` targets the **same partition RAUC uses for `/data`** (`part:3`
> in the `--rauc` layout), you **must** also set `LUKS_DATA_MOUNT = "/data"` in
> `local.conf`. `rauc-setup-env.sh` hardcodes that partition to mount at `/data`;
> leaving `LUKS_DATA_MOUNT` at its default (`/appdata`) makes RAUC's own state land on
> an unrelated, unencrypted partition -- silently, with no error at boot. Encrypting a
> separate `--appdata` partition instead needs no such change.

> [!TIP]
> `LUKS_DATA_KEY_MODE` defaults to `"tpm"`. The alternative, `"keyfile"`
> (`LUKS_DATA_KEY_MODE = "keyfile"`), has **no security** — the key ships in plaintext
> in every unit built from this image — and exists only for bring-up before the TPM
> path is verified. See `conf/include/ecu150v2-luks.inc` for how to generate that key.

### 2. Build and flash

```console
foo@bar:~/yocto/bld-wayland$ bitbake imx-image-core
```

Flash a card with a partition matching `LUKS_DATA_DEVICE` — either RAUC's own `part:3`
(`--rauc`), or a dedicated one via `--appdata` (see
[`tools/flash/README.md`](tools/flash/README.md)):

```console
foo@bar:~/yocto$ sudo ./tools/flash/ecu150v2_flash.sh \
    --device /dev/sdX \
    --images bld-wayland/tmp/deploy/images/ecu150v2 \
    --appdata \
    --yocto  imx-image-core-ecu150v2.rootfs.tar.zst
```

### 3. First boot and verification

With the default `LUKS_DATA_AUTO_PROVISION = "1"`, the partition is formatted and
enrolled with the TPM automatically on first boot — no manual step needed:

```console
root@ecu150v2:~$ journalctl -u ecu150v2-luks-data      # provisioning done
root@ecu150v2:~$ mountpoint /appdata                   # or /data, per LUKS_DATA_MOUNT
root@ecu150v2:~$ cryptsetup isLuks --type luks2 <target-partition> && echo "is LUKS"
root@ecu150v2:~$ cryptsetup close data && cryptsetup open <target-partition> data
# "data" here is the mapper name (LUKS_DATA_MAPPER, default "data" -> /dev/mapper/data),
# not a placeholder. No password prompt on open = the TPM unlock is working.
```


