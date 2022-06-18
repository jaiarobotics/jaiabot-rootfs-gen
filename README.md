# JaiaBot rootfs generation.

This repository contains [live-build](https://live-team.pages.debian.net/live-manual/html/live-manual/index.en.html) scripts for generating an Ubuntu root filesystem for booting on the embedded Linux computer (currently Raspberry Pi).

## Quick usage

### Install Dependencies on Build machine

Install dependencies (tested on Ubuntu 20.04):

```
sudo apt install live-build qemu-user-static
```

### Run script to create USB key image

Creates (in current working directory) jaiabot_img-{version}.img (can be installed with `dd` or similar):

```
sudo jaiabot-rootfs-gen/scripts/master_raspi_base_image.sh
```

