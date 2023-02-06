#!/bin/bash

# Simple script to import N copies of a jaiabot OVA to VirtualBox

#set -x
set -u -e

source includes/import_utils.sh

if [ ! $# -eq 4 ]; then
   echo "Usage ./import_vms.sh vm.ova n_bots n_hubs fleet_id"
   exit 1;
fi

OVA="$1"
N_BOTS="$2"
N_HUBS="$3"
FLEET="$4"

OVA_BASENAME=$(basename $OVA)
OVA_EXTENSION="${OVA_BASENAME##*.}"
GROUP="/${OVA_BASENAME%.*}"

GROUP=$(echo "$GROUP" | sed 's/[\+~\.]/_/g')

if vboxmanage list groups | grep -q "\"${GROUP}\""; then
    echo "Group \"${GROUP}\" already exists. Please delete all VMs from this group before re-importing"
    exit 1;
fi

if [[ "${OVA_EXTENSION}" != "ova" ]]; then
    echo "Expecting .ova for first argument, got $OVA"
    exit 1;
fi

N_CPUS=4

for n in `seq 0 $((N_BOTS-1))`; do
    echo "####### IMPORTING BOT $n ################"
    VMNAME="bot$n"
    vboxmanage import "$OVA" --options=importtovdi --vsys 0 --vmname "$VMNAME" --cpus ${N_CPUS} --group "$GROUP"
    find_uuid $VMNAME $GROUP
    echo "Imported UUID: $UUID"
    find_diskuuid $UUID
    VBoxManage modifyvm $UUID --usb-xhci on
    echo "Disk UUID: $DISKUUID"
    write_preseed $DISKUUID $n bot
done

for n in `seq 0 $((N_HUBS-1))`; do
    echo "####### IMPORTING HUB $n ################"
    VMNAME="hub$n"
    vboxmanage import "$OVA" --options=importtovdi --vsys 0 --vmname "$VMNAME" --cpus ${N_CPUS} --group "$GROUP"
    find_uuid $VMNAME $GROUP
    echo "Imported UUID: $UUID"
    find_diskuuid $UUID
    VBoxManage modifyvm $UUID --usb-xhci on
    echo "Disk UUID: $DISKUUID"
    write_preseed $DISKUUID $n hub
done

