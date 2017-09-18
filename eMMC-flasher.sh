#!/bin/bash

MACHINE=beaglebone

if [ "x${1}" = "x" ]; then
    echo -e "\nUsage: ${0} <block device> <path to yocto_tmp folder >\n"
    echo -e "Example: sudo $0 sdc /yocto/build/tmp"
    exit 0
fi

if [ ! -d /media/card ]; then
    echo "Temporary mount point [/media/card] not found"
    exit 1
fi

if [ "x${2}" = "x" ]; then
    echo -e "\nUsage: ${0} <block device> <tmp directory >\n"
    echo -e "Example: sudo $0 sdc /yocto/build/tmp"
    exit 0
else
        OETMP=${2}
fi

echo -e "++++++++ Create partition for eMMC ++++++++"

function ver() {
        printf "%03d%03d%03d" $(echo "$1" | tr '.' ' ')
}

if [ -n "$1" ]; then
    DRIVE=/dev/$1
else
    echo -e "\nUsage: sudo $0 <device>\n"
    echo -e "Example: sudo $0 sdb\n"
    exit 1
fi

if [ "$DRIVE" = "/dev/sda" ] ; then
    echo "Sorry, not going to format $DRIVE"
    exit 1
fi


echo -e "\nWorking on $DRIVE\n"

#make sure that the SD card isn't mounted before we start
if [ -b ${DRIVE}1 ]; then
    umount ${DRIVE}1
    umount ${DRIVE}2
elif [ -b ${DRIVE}p1 ]; then
    umount ${DRIVE}p1
    umount ${DRIVE}p2
else
    umount ${DRIVE}
fi


SIZE=`sudo fdisk -l $DRIVE | grep "$DRIVE" | cut -d' ' -f5 | grep -o -E '[0-9]+'`

echo DISK SIZE – $SIZE bytes

if [ "$SIZE" -lt 1800000000 ]; then
    echo "Require an SD card of at least 2GB"
    exit 1
fi

# new versions of sfdisk don't use rotating disk params
sfdisk_ver=`sfdisk --version | awk '{ print $4 }'`

if [ $(ver $sfdisk_ver) -lt $(ver 2.26.2) ]; then
        CYLINDERS=`echo $SIZE/255/63/512 | bc`
        echo "CYLINDERS – $CYLINDERS"
        SFDISK_CMD="sudo sfdisk --force -D -uS -H255 -S63 -C ${CYLINDERS}"
else
        SFDISK_CMD="sudo sfdisk"
fi

echo -e "\nOkay, here we go ...\n"

echo -e "=== Zeroing the MBR ===\n"
sudo dd if=/dev/zero of=$DRIVE bs=1024 count=1024

# Minimum required 2 partitions
# Sectors are 512 bytes
# 0     : 64KB, no partition, MBR then empty
# 128   : 64 MB, FAT partition, bootloader 
# 131200: 2GB+, linux partition, root filesystem

echo -e "\n=== Creating 2 partitions ===\n"
{
echo 128,131072,0x0C,*
echo 131200,+,0x83,-
} | $SFDISK_CMD $DRIVE


sleep 1

echo -e "\n=== Done! ===\n"

echo -e "++++++++ Copying bootloader and boot environment ++++++++"

if [ -z "$OETMP" ]; then
    echo "Working from local directory"
    SRCDIR=.
else
    echo "OETMP: $OETMP"

    if [ ! -d ${OETMP}/deploy/images/${MACHINE} ]; then
        echo "Directory not found: ${OETMP}/deploy/images/${MACHINE}"
        exit 1
    fi

    SRCDIR=${OETMP}/deploy/images/${MACHINE}
fi 

if [ ! -f ${SRCDIR}/MLO-${MACHINE} ]; then
    echo "File not found: ${SRCDIR}/MLO-${MACHINE}"
    exit 1
fi

if [ ! -f ${SRCDIR}/u-boot-${MACHINE}.img ]; then
    echo "File not found: ${SRCDIR}/u-boot-${MACHINE}.img"
    exit 1
fi

if [ -b ${1} ]; then
    DEV=${1}
elif [ -b "/dev/${1}1" ]; then
    DEV=/dev/${1}1
elif [ -b "/dev/${1}p1" ]; then
    DEV=/dev/${1}p1
else
    echo "Block device not found: /dev/${1}1 or /dev/${1}p1"
    exit 1
fi

echo "Formatting FAT partition on $DEV"
sudo mkfs.vfat -F 32 ${DEV} -n BOOT

echo "Mounting $DEV"
sudo mount ${DEV} /media/card

echo "Copying MLO"
sudo cp ${SRCDIR}/MLO /media/card/MLO

echo "Copying u-boot"
sudo cp ${SRCDIR}/u-boot.img /media/card/u-boot.img

if [ -f ${SRCDIR}/uEnv.txt ]; then
    echo "Copying ${SRCDIR}/uEnv.txt to /media/card"
    sudo cp ${SRCDIR}/uEnv.txt /media/card
elif [ -f ./uEnv.txt ]; then
    echo "Copying ./uEnv.txt to /media/card"
    sudo cp ./uEnv.txt /media/card
fi

echo "Unmounting ${DEV}"
sudo umount ${DEV}

echo -e "\n=== Done! ===\n"

echo -e "++++++++ Extracting root filesystem ++++++++"

if [ ! -f "${SRCDIR}/core-olli-image-beaglebone.tar.xz" ]; then
        echo "File not found: ${SRCDIR}/core-olli-image-beaglebone.tar.xz"
        exit 1
fi

if [ -b ${1} ]; then
        DEV=${1}
elif [ -b "/dev/${1}2" ]; then
        DEV=/dev/${1}2
elif [ -b "/dev/${1}p2" ]; then
        DEV=/dev/${1}p2
else
        echo "Block device not found: /dev/${1}2 or /dev/${1}p2"
        exit 1
fi

echo "Formatting $DEV as ext4"
sudo mkfs.ext4 -q -L ROOT $DEV

echo "Mounting $DEV"
sudo mount $DEV /media/card

echo "Extracting core-olli-image-beaglebone.tar.xz to /media/card"
sudo tar -C /media/card -xvf ${SRCDIR}/core-olli-image-beaglebone.tar.xz && sync

echo "Unmounting ${DEV}"
sudo umount ${DEV}

echo -e "\n=== Done! ===\n"