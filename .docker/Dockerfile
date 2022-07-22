# Manually build this image with:
#
#     docker build --tag gobysoft/jaiabot-master-raspi:1.0.0 .
#     docker push gobysoft/jaiabot-master-raspi:1.0.0

FROM ubuntu:focal

# Install dependencies
RUN apt-get update && \
    apt-get install -y \
        binfmt-support \
        dosfstools \
        gcc-aarch64-linux-gnu \
        git \
        kpartx \
        live-build \
        qemu-user-static \
        sudo \
        wget
