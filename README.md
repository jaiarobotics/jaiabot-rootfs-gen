# JaiaBot rootfs generation.

This repository contains [live-build](https://live-team.pages.debian.net/live-manual/html/live-manual/index.en.html) scripts for generating an Ubuntu root filesystem for booting on the embedded Linux computer (currently Raspberry Pi).

## Quick usage

### Install Dependencies on Build machine

Install dependencies (tested on Ubuntu 20.04):

```
sudo apt install live-build qemu-user-static
```

### Run live-build to generate rootfs

Run live-build (`lb`):

```
cd jaiabot-rootfs-gen
sudo lb clean
lb config
sudo lb build
```
