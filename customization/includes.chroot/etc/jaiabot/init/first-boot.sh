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
JAIABOT_DATA_MOUNTPOINT="/var/log"

echo -e "\nResizing partition $JAIABOT_DATA_PARTITION_NUMBER of: $JAIABOT_DATA_DISK\n"
(set -x; growpart $JAIABOT_DATA_DISK $JAIABOT_DATA_PARTITION_NUMBER || [ $? -lt 2 ])

echo -e "\nResizing filesystem: $JAIABOT_DATA_PARTITION\n"
# btrfs filesystem resize requires mount point as the argument
(set -x; btrfs filesystem resize max $JAIABOT_DATA_MOUNTPOINT)

# allow jaia user to write logs
chown -R jaia:jaia /var/log/jaiabot

echo "###############################################"
echo "## Setting up i2c                            ##"
echo "###############################################"

groupadd i2c
chown :i2c /dev/i2c-1
chmod g+rw /dev/i2c-1
usermod -aG i2c ubuntu
udev_entry='KERNEL=="i2c-[0-9]*", GROUP="i2c"'
grep "$udev_entry" /etc/udev/rules.d/10-local_i2c_group.rules || echo "$udev_entry" >> /etc/udev/rules.d/10-local_i2c_group.rules

echo "###############################################"
echo "## Setting up swap partition                 ##"
echo "###############################################"

JAIABOT_SWAPFILE=${JAIABOT_DATA_MOUNTPOINT}/swapfile

fallocate -l 2G $JAIABOT_SWAPFILE
chmod 600 $JAIABOT_SWAPFILE
mkswap $JAIABOT_SWAPFILE
swapon $JAIABOT_SWAPFILE
fstab_entry="$JAIABOT_SWAPFILE swap swap defaults 0 0"
grep "$fstab_entry" /etc/fstab || echo "$fstab_entry" >> /etc/fstab

echo "###############################################"
echo "## Disable getty on /dev/ttyS0               ##"
echo "###############################################"

systemctl stop serial-getty@ttyS0.service
systemctl disable serial-getty@ttyS0.service

echo "###############################################"
echo "## Setting up device links                   ##"
echo "###############################################"

python3 /etc/jaiabot/init/setup_device_links.py

echo "###############################################"
echo "## Install jaiabot-embedded package          ##"
echo "###############################################"

run_wt_yesno "Do you want to install and configure the jaiabot-embedded Debian package?" && apt install -y /opt/jaiabot-embedded*.deb

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
