#!/bin/bash -e
# Copyright 2022: JaiaRobotics LLC
# Distribution per terms of original project (below)
#
# Forked from original project:
#
# Copyright (C) 2019 Woods Hole Oceanographic Institution
#
# This file is part of the CGSN Mooring Project ("cgsn-mooring").
#
# cgsn-mooring is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# cgsn-mooring is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with cgsn-mooring in the COPYING.md file at the project root.
# If not, see <http://www.gnu.org/licenses/>.
################################################################################
# This tool creates a bootable Raspberry Pi image that is ready to flash to an
# SD card. Add packages to the image using the install_into_image.sh tool.
#
# Options:
#
#     --firmware firmware.tgz
#         The path to a tarball containing pre-built Raspberry Pi boot partition
#         files. If omitted, a copy will be downloaded.
#
#     --dest directory|file.img
#         If an existing directory, the image file will be written to it using
#         the default name format. If not,
#         assumed to be the specific image name you want.
#
#     --debug
#         If an error happens, do not remove the scratch directory.
#
# This script is invoked by the raspi-image-master job in the cgsn_mooring
# project's CircleCI but can also be invoked directly.
#
# Please see the cgsn_mooring/.circleci/master-raspi-docker/Dockerfile for a
# list of packages that may be needed for this tool.
################################################################################

shopt -s nullglob
. "$(cd "$(dirname "$0")"; pwd)"/includes/image_utils.sh

TOPLEVEL="$(cd "$(dirname "$0")"; git rev-parse --show-toplevel)"

ROOTFS_BUILD_TAG="$(cd "$(dirname "$0")"; git describe --tags HEAD | sed 's/_/~/' | sed 's/-/+/g')"
DATE="$(date +%Y%m%d)"
WORKDIR="$(mktemp -d)"
STARTDIR="$(pwd)"
RASPI_FIRMWARE_VERSION=1.20220331

# Default options that might be overridden
ROOTFS_BUILD_PATH="$TOPLEVEL"
DEFAULT_IMAGE_NAME=jaiabot_img-"$ROOTFS_BUILD_TAG".img
OUTPUT_IMAGE_PATH="$(pwd)"/"$DEFAULT_IMAGE_NAME"

# Ensure user is root
if [ "$UID" -ne 0 ]; then
    echo "This script must be run as root; e.g. using 'sudo'" >&2
    exit 1
fi


# Set up an exit handler to clean up after ourselves
function finish {
  ( # Run in a subshell to ignore errors
    set +e
    
    # Undo changes to the binfmt configuration
    reset_binfmt_rules
  
    # Unmount the partitions
    sudo umount "$ROOTFS_PARTITION"/boot/firmware
    sudo umount "$ROOTFS_PARTITION"/dev
    sudo umount "$ROOTFS_PARTITION"
    sudo umount "$BOOT_PARTITION"

    # Detach the loop devices
    detach_image "$SD_IMAGE_PATH"
    
    # Remove the scratch directory
    [ -z "$DEBUG" ] && cd / && rm -Rf "$WORKDIR"
  ) &>/dev/null || true
}
trap finish EXIT


# Parse command-line options
while [[ $# -gt 0 ]]; do
  OPTION="$1"
  shift
  case "$OPTION" in
  --firmware)
    FIRMWARE_PATH="$(cd "$(dirname "$1")"; pwd)/$(basename "$1")"
    shift
    ;;
  --dest)
    if [ -d "$1" ]; then
      OUTPUT_IMAGE_PATH="$(cd "$1"; pwd)"/"$DEFAULT_IMAGE_NAME"
    else
      OUTPUT_IMAGE_PATH="$(cd "$(dirname "$1")"; pwd)/$(basename "$1")"
    fi
    shift
    ;;
  --rootfs-build)
    ROOTFS_BUILD_PATH="$(cd "$1"; pwd)"
    shift
    ;;
  --debug)
    DEBUG=1
    set -x
    ;;
  *)
    echo "Unexpected argument: $KEY" >&2
    exit 1
  esac
done

# Test that executing foreign binaries under QEMU will work
if ! enable_binfmt_rule qemu-aarch64; then
  echo "This system cannot execute ARM binaries under QEMU" >&2
  exit 1
fi


# Let's go!
echo "Building bootable Raspberry Pi image in $WORKDIR"
cd "$WORKDIR"

# Create a 2 GB image
SD_IMAGE_PATH="$OUTPUT_IMAGE_PATH"
dd if=/dev/zero of="$SD_IMAGE_PATH" bs=1M count=2048 conv=sparse status=none

# Apply the partition map
sfdisk --quiet "$SD_IMAGE_PATH" <<EOF
label: dos
unit: sectors

boot   : start=        2048, size=      262144, type=b, bootable
rootfs : start=      264192, size=     3930112, type=83
EOF

# Set up loop device for the partitions
attach_image "$SD_IMAGE_PATH" BOOT_DEV ROOTFS_DEV

# Format the partitions
sudo mkfs.vfat -F 32 -n boot "$BOOT_DEV"
sudo mkfs.ext4 -L rootfs "$ROOTFS_DEV"

# Mount the partitions
mkdir boot rootfs
BOOT_PARTITION="$WORKDIR"/boot 
ROOTFS_PARTITION="$WORKDIR"/rootfs

sudo mount "$BOOT_DEV" "$BOOT_PARTITION"
sudo mount "$ROOTFS_DEV" "$ROOTFS_PARTITION"

# Build the rootfs
cp -r "$ROOTFS_BUILD_PATH" rootfs-build
cd rootfs-build
lb clean
lb config
#mkdir -p config/includes.chroot/etc/cgsn-mooring
#echo "CGSN_IMAGE_VERSION=$ROOTFS_BUILD_TAG" >> config/includes.chroot/etc/cgsn-mooring/version
#echo "CGSN_IMAGE_BUILD_DATE=\"`date -u`\""  >> config/includes.chroot/etc/cgsn-mooring/version
lb build
cd ..

# Install the rootfs tarball to the partition
sudo tar -C "$ROOTFS_PARTITION" --strip-components 1 \
  -xpzf rootfs-build/binary-tar.tar.gz

# Download the Raspberry Pi firmware tarball if we don't have it
if [ -z "$FIRMWARE_PATH" ]; then
  wget -O firmware.tgz https://github.com/raspberrypi/firmware/archive/refs/tags/${RASPI_FIRMWARE_VERSION}.tar.gz
  FIRMWARE_PATH="$WORKDIR"/firmware.tgz
fi

# Extract the firmware's boot/ directory to the boot partition
FIRMWARE_TOPLEVEL="$(tar -tf "$FIRMWARE_PATH" | head -n 1 | sed -e 's,/*$,,')"
sudo tar --exclude 'kernel*' -C "$BOOT_PARTITION" --strip-components 2 \
  -xzpf "$FIRMWARE_PATH" "$FIRMWARE_TOPLEVEL"/boot/

# Write configuration files for the Raspberry Pi
cat >> "$BOOT_PARTITION"/config.txt <<EOF
# Run in 64-bit mode
arm_64bit=1

# Disable compensation for displays with overscan
disable_overscan=1

[cm4]
# Enable host mode on the 2711 built-in XHCI USB controller.
# This line should be removed if the legacy DWC2 controller is required
# (e.g. for USB device mode) or if USB support is not required.
otg_mode=1

[all]

[pi4]
# Run as fast as firmware / board allows
arm_boost=1

[all]
initramfs initrd.img followkernel
kernel=vmlinuz
EOF
cat > "$BOOT_PARTITION"/cmdline.txt <<EOF
console=serial0,115200 console=tty1 root=LABEL=rootfs rootfstype=ext4 fsck.repair=yes rootwait
EOF

# Flash the kernel
sudo mount -o bind "$BOOT_PARTITION" "$ROOTFS_PARTITION"/boot/firmware
sudo mount -o bind /dev "$ROOTFS_PARTITION"/dev
sudo chroot "$ROOTFS_PARTITION" flash-kernel

# Fin.
echo "Raspberry Pi image created at $OUTPUT_IMAGE_PATH"
