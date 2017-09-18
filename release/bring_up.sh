#!/bin/bash

MACHINE=beaglebone

diff(){
    awk 'BEGIN{RS=ORS=" "}
        {NR==FNR?a[$0]++:a[$0]--}
        END{for(k in a)if(a[k])print k}' <(echo -n "${!1}") <(echo -n "${!2}")
}

is_file_exists(){
    local f="$1"
    [[ -f "$f" ]] && return 0 || return 1
}

usage(){
    echo -e "\n Usage: ${0} <path to yocto_tmp folder >\n"
    echo -e "Example: sudo $0 /yocto/build/tmp"
}

if [ "x${1}" = "x" ]; then
    usage
    exit 0
else
        OETMP=${1}
fi

echo "Please do not insert any USB Sticks"\
        "or mount external hdd during the procedure."
echo 

read -p "When the Mainboard is connected in USB Boot mode press [yY]." -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    before=($(ls /dev | grep "sd[a-z]$"))

    if ( ! is_file_exists usb_flasher)
    then
        echo "Please make the project then execute the script!"
        exit 1
    fi

    echo
    echo "Putting the Mainboard into flashing mode!"
    echo

    sudo ./usb_flasher
    rc=$?
    if [[ $rc != 0 ]];
    then
        echo "The Mainboard cannot be put in USB Flasing mode. Send "\
                "logs to vvu@vdev.ro together with the serial output from the"\
                "BeagleBone Black."
        exit $rc
    fi

    echo -n "Waiting for the Mainboard to be mounted"
    for i in {1..20}
    do
        echo -n "."
        sleep 1
    done
    echo 

    after=($(ls /dev | grep "sd[a-z]$"))
    bbb=($(diff after[@] before[@]))
    
    if [ -z "$bbb" ];
    then
        echo "The Mainboard cannot be detected. Either it has not been"\
                " mounted or the g_mass_storage module failed loading."
        exit 1
    fi
    
    if [ ${#bbb[@]} != "1" ]
    then
        echo "You inserted an USB stick or mounted an external drive. Please "\
            "rerun the script without doing that."
        exit 1
    fi

    read -p "Are you sure the Mainboard is mounted at /dev/$bbb?[yY]" -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo "Flashing now, be patient. It will take ~5 minutes!"
        echo -e "========================================================="
        echo -e "++++++++++++++ Create partition for eMMC ++++++++++++++++"
        echo -e "========================================================="

        function ver() {
                printf "%03d%03d%03d" $(echo "$bbb" | tr '.' ' ')
        }

        if [ -n "$bbb" ]; then
            DRIVE=/dev/$bbb
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

        echo -e "========================================================="
        echo -e "++++++++ Copying bootloader and boot environment ++++++++"
        echo -e "========================================================="

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

        if [ -b ${bbb} ]; then
            DEV=${bbb}
        elif [ -b "/dev/${bbb}1" ]; then
            DEV=/dev/${bbb}1
        elif [ -b "/dev/${bbb}p1" ]; then
            DEV=/dev/${bbb}p1
        else
            echo "Block device not found: /dev/${bbb}1 or /dev/${bbb}p1"
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

        echo -e "========================================================="
        echo -e "+++++++++++++ Extracting root filesystem ++++++++++++++++"
        echo -e "========================================================="

        if [ ! -f "${SRCDIR}/core-olli-image-beaglebone.tar.xz" ]; then
                echo "File not found: ${SRCDIR}/core-olli-image-beaglebone.tar.xz"
                exit 1
        fi

        if [ -b ${bbb} ]; then
                DEV=${bbb}
        elif [ -b "/dev/${bbb}2" ]; then
                DEV=/dev/${bbb}2
        elif [ -b "/dev/${bbb}p2" ]; then
                DEV=/dev/${bbb}p2
        else
                echo "Block device not found: /dev/${bbb}2 or /dev/${bbb}p2"
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
        echo "Flashing done !!!"
        echo "Please remove power from your board and plug it again."\
                        "You will boot in the new OS!"
    fi
fi