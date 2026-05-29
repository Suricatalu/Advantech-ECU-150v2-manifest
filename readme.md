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
