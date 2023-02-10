#!/bin/bash

# Simple script to import N copies of a jaiabot OVA to VirtualBox

set -x

if [ ! $# -eq 2 ]; then
   echo "Usage ./import_vms.sh vm.ova n_copies"
   exit 1;
fi

OVA="$1"
N="$2"

OVA_BASENAME=$(basename $OVA)
OVA_EXTENSION="${OVA_BASENAME##*.}"
GROUP="/${OVA_BASENAME%.*}"

GROUP=$(echo "$GROUP" | sed 's/[\+~\.]/_/g')

if [[ "${OVA_EXTENSION}" != "ova" ]]; then
    echo "Expecting .ova for first argument, got $OVA"
    exit 1;
fi

for n in `seq 1 $N`; do
    VBoxManage import "$OVA" --options=importtovdi --vsys 0 --vmname jaia$n --cpus `nproc` --group "$GROUP"
done
