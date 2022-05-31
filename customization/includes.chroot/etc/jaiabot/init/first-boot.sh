#!/bin/bash
set -e -u 

# 
# This script configures the new image. It should only be run once 
# on first boot
# 

source /etc/jaiabot/init/include/wt_tools.sh

if [ ! "$UID" -eq 0 ]; then 
    echo "This script must be run as root" >&2
    exit 1;
fi

echo "###########################################"
echo "###########################################"
echo "##### jaiabot first boot init script #####"
echo "###########################################"
echo "###########################################"

source /etc/jaiabot/version
run_wt_yesno "JaiaBot First Boot" "Image Version: $JAIABOT_IMAGE_VERSION.\nThis is the first boot of the machine since this image was written.\n\nDo you want to run the first-boot setup (RECOMMENDED)?" || exit 0

echo "######################################################"
echo "## Set Password                                     ##"
echo "######################################################"

run_wt_password "Password" "Enter a new password for jaia"
[ $? -eq 0 ] || exit 1
echo "jaia:$WT_PASSWORD" | chpasswd

echo "###############################################################"
echo "## Stress Tests                                              ##" 
echo "###############################################################"

run_wt_yesno "Hardware checks and stress test" \
             "Do you want to run the hardware checks and stress test?" && source /etc/jaiabot/init/board-check.sh

echo "###############################################"
echo "## Resizing data partition to fill disk      ##"
echo "###############################################"

JAIABOT_DATA_PARTITION=$(realpath /dev/disk/by-label/data)
JAIABOT_DATA_DISK=${JAIABOT_DATA_PARTITION:0:(-1)}
JAIABOT_DATA_PARTITION_NUMBER=${JAIABOT_DATA_PARTITION:(-1)}

echo -e "\nResizing partition $JAIABOT_DATA_PARTITION_NUMBER of: $JAIABOT_DATA_DISK\n"
(set -x; growpart $JAIABOT_DATA_DISK $JAIABOT_DATA_PARTITION_NUMBER || [ $? -lt 2 ])

echo -e "\nResizing filesystem: $JAIABOT_DATA_PARTITION\n"
(set -x; resize2fs $JAIABOT_DATA_PARTITION)

echo "###############################################################"
echo "## Removing first-boot hooks so that this does not run again ##"
echo "###############################################################"

echo -e "\nUpdating /boot/firmware/cmdline.txt and /home/jaia/.profile to remove first-boot entries\n"

mount -o remount,rw /boot/firmware
sed -i 's/overlayroot=disabled//' /boot/firmware/cmdline.txt 
sed -i '/FIRST BOOT/d' /etc/issue
echo "JAIABOT_FIRST_BOOT_DATE=\"`date -u`\"" >> /etc/jaiabot/version

# Finish

run_wt_yesno "First boot provisioning complete\n" \
             "Do you want to reboot into the complete system?" && reboot
