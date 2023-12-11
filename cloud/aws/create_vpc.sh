#!/bin/bash

# Check if necessary parameters are provided
if (( "$#" != 1 )); then
    echo "Usage: $0 vpc.conf"
    exit 1
fi

set -a
source $1
set +a

set -u -e

 set -x


SCRIPT_PATH=$(dirname "$0")
FLEET_ID_HEX=$(printf '%x\n' ${FLEET_ID})

handle_failure() {
    echo "FAILURE"
    exit 1
}
trap handle_failure ERR


VPC_CIDR_BLOCK="10.23.0.0/16"
# maps onto real fleet IP assignment
WLAN_CIDR_BLOCK="10.23.${FLEET_ID}.0/24"
CLOUDHUB_ID=30
CLOUDHUB_WLAN_IP_ADDRESS="10.23.${FLEET_ID}.$((CLOUDHUB_ID+10))"
# IPv6 address to use for VirtualFleet VPN (fd6e:cf0d:aefa:FLEET_ID_HEX::/48)
VIRTUALFLEET_VPN_CLIENT_IPV6="fd6e:cf0d:aefa:${FLEET_ID_HEX}::2:1"
VIRTUALFLEET_VPN_SERVER_IPV6="fd6e:cf0d:aefa:${FLEET_ID_HEX}::0:30"
# IPv6 address to use for VirtualFleet VPN (fd0f:77ac:4fdf:FLEET_ID_HEX::/48)
CLOUDHUB_VPN_CLIENT_IPV6="fd0f:77ac:4fdf:${FLEET_ID_HEX}::2:1"
CLOUDHUB_VPN_SERVER_IPV6="fd0f:77ac:4fdf:${FLEET_ID_HEX}::0:30"

# Create a VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR_BLOCK" --amazon-provided-ipv6-cidr-block --query 'Vpc.VpcId' --output text)
echo "Created VPC with ID: $VPC_ID"

VPC_IPV6_BLOCK=$(aws ec2 describe-vpcs --vpc-id ${VPC_ID} --query Vpcs[].Ipv6CidrBlockAssociationSet[].Ipv6CidrBlock --output text)
echo "Created VPC IPV6 block: $VPC_IPV6_BLOCK"

# Create an Internet Gateway
INTERNET_GATEWAY_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
echo "Created Internet Gateway with ID: $INTERNET_GATEWAY_ID"

# Attach the Internet Gateway to the VPC
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$INTERNET_GATEWAY_ID"
echo "Attached Internet Gateway to VPC"

# Create just one subnet: eth0 which has the same IP assignment as wlan0 in the real fleet
SUBNET_ETH_IPV6=$(echo ${VPC_IPV6_BLOCK} | sed 's|00::/56|00::/64|')
SUBNET_ETH_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$WLAN_CIDR_BLOCK" --ipv6-cidr-block "$SUBNET_ETH_IPV6" --query 'Subnet.SubnetId' --output text)
echo "Created Subnet with ID: $SUBNET_ETH_ID and IPv6: ${SUBNET_ETH_IPV6}"

aws ec2 modify-subnet-attribute --assign-ipv6-address-on-creation --subnet-id ${SUBNET_ETH_ID}


# Create a Security Group
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name "jaia__SecurityGroup__${JAIA_CUSTOMER_NAME}" --description "jaia__${JAIA_CUSTOMER_NAME} Security Group" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
echo "Created Security Group with ID: $SECURITY_GROUP_ID"

# Set Up Security Group Rules
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0}]',Ipv6Ranges='[{CidrIpv6=::/0}]'
echo "Allowed SSH (port 22) on Security Group"

aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --ip-permissions IpProtocol=udp,FromPort=51820,ToPort=51821,IpRanges='[{CidrIp=0.0.0.0/0}]',Ipv6Ranges='[{CidrIpv6=::/0}]'
echo "Allowed UDP ports 51820-51821 (Wireguard) on Security Group"

# Modify the Main Route Table to use the Internet Gateway
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id "$ROUTE_TABLE_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$INTERNET_GATEWAY_ID"
aws ec2 create-route --route-table-id "$ROUTE_TABLE_ID" --destination-ipv6-cidr-block ::/0 --gateway-id "$INTERNET_GATEWAY_ID"
echo "Modified the main route table to use the Internet Gateway"

## Launch the actual VM (CloudHub)
USER_DATA_FILE_IN="${SCRIPT_PATH}/cloud-init-user-data.txt.in"
USER_DATA_FILE="${SCRIPT_PATH}/cloud-init-user-data.txt"
DISK_SIZE_GB=32

# replace some {{MACROS}} in the user data
cp ${USER_DATA_FILE_IN} ${USER_DATA_FILE}
sed -i "s/{{FLEET_ID}}/${FLEET_ID}/g" ${USER_DATA_FILE}
sed -i "s/{{CLOUDHUB_ID}}/${CLOUDHUB_ID}/g" ${USER_DATA_FILE}
sed -i "s|{{VPN_WIREGUARD_PUBKEY}}|${VPN_WIREGUARD_PUBKEY}|g" ${USER_DATA_FILE}
sed -i "s/{{VIRTUALFLEET_VPN_CLIENT_IPV6}}/${VIRTUALFLEET_VPN_CLIENT_IPV6}/g" ${USER_DATA_FILE}
sed -i "s/{{VIRTUALFLEET_VPN_SERVER_IPV6}}/${VIRTUALFLEET_VPN_SERVER_IPV6}/g" ${USER_DATA_FILE}
sed -i "s/{{CLOUDHUB_VPN_CLIENT_IPV6}}/${CLOUDHUB_VPN_CLIENT_IPV6}/g" ${USER_DATA_FILE}
sed -i "s/{{CLOUDHUB_VPN_SERVER_IPV6}}/${CLOUDHUB_VPN_SERVER_IPV6}/g" ${USER_DATA_FILE}

# Find the newest AMI matching the tags
AMI_ID=$(aws ec2 describe-images --filters "Name=tag:jaiabot-rootfs-gen_repository,Values=${REPO}" "Name=tag:jaiabot-rootfs-gen_repository_version,Values=${REPO_VERSION}" --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

if [ "$AMI_ID" == "None" ]; then
    echo "No matching AMI found for repo: ${REPO} and version: ${REPO_VERSION}. Available AMIs include: "
    aws ec2 describe-images --filters "Name=tag:jaiabot-rootfs-gen_repository,Values=*"
    exit 1
fi

echo "Newest matching AMI ID: $AMI_ID"

# Launch the EC2 instance w/ two network interfaces
INSTANCE_ID=$(aws ec2 run-instances \
                  --image-id "$AMI_ID" \
                  --instance-type "$INSTANCE_TYPE" \
                  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$DISK_SIZE_GB,\"VolumeType\":\"gp3\"}}]" \
                  --user-data file://"$USER_DATA_FILE" \
                  --network-interfaces "[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"SubnetId\":\"$SUBNET_ETH_ID\",\"PrivateIpAddress\":\"$CLOUDHUB_WLAN_IP_ADDRESS\",\"Groups\":[\"$SECURITY_GROUP_ID\"]}]" \
                  --query "Instances[0].InstanceId" --output text)

echo "EC2 Instance launched successfully with ID: $INSTANCE_ID"


# Wait for the instance to be in a running state
echo "Waiting for instance to be in 'running' state..."
while state=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[].Instances[].State.Name' --output text); [ "$state" != "running" ]; do
  sleep 5
  echo "Instance state: $state"
done

ENI_ID_0=$(aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" "Name=attachment.device-index,Values=0" --query  NetworkInterfaces[0].NetworkInterfaceId --output text)
echo "ENI ID: $ENI_ID_0"

# Allocate an Elastic IP Address
EIP_ALLOCATION_ID=$(aws ec2 allocate-address --query 'AllocationId' --output text)
echo "Allocated Elastic IP Address with Allocation ID: $EIP_ALLOCATION_ID"

PUBLIC_IPV4_ADDRESS=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOCATION_ID --query "Addresses[0].PublicIp" --output text)

echo "Instance is running. Proceeding to associate Elastic IP Address."

# Associate the Elastic IP Address with the EC2 Instance
aws ec2 associate-address --network-interface-id "$ENI_ID_0" --allocation-id "$EIP_ALLOCATION_ID"
echo "Associated Elastic IP Address with EC2 Instance"

# Tag the Resources
aws ec2 create-tags --resources "$VPC_ID" "$SUBNET_ETH_ID" "$SECURITY_GROUP_ID" "$INTERNET_GATEWAY_ID" "$INSTANCE_ID" "$ROUTE_TABLE_ID" "$EIP_ALLOCATION_ID" "$ENI_ID_0" \
    --tags \
    "Key=jaia_customer,Value=${JAIA_CUSTOMER_NAME}" \
    "Key=jaia_fleet,Value=${FLEET_ID}" \
    "Key=jaiabot-rootfs-gen_repository,Value=${REPO}" \
    "Key=jaiabot-rootfs-gen_repository_version,Value=${REPO_VERSION}"

aws ec2 create-tags --resources "$VPC_ID"  --tags "Key=Name,Value=jaia__VPC__${JAIA_CUSTOMER_NAME}"
aws ec2 create-tags --resources "$SUBNET_ETH_ID"  --tags "Key=Name,Value=jaia__Subnet_Ethernet__${JAIA_CUSTOMER_NAME}"
aws ec2 create-tags --resources "$SECURITY_GROUP_ID"  --tags "Key=Name,Value=jaia__SecurityGroup__${JAIA_CUSTOMER_NAME}"
aws ec2 create-tags --resources "$INTERNET_GATEWAY_ID"  --tags "Key=Name,Value=jaia__InternetGateway__${JAIA_CUSTOMER_NAME}"
aws ec2 create-tags --resources "$ROUTE_TABLE_ID"  --tags "Key=Name,Value=jaia__RouteTable__${JAIA_CUSTOMER_NAME}"

# VM specific
aws ec2 create-tags --resources "$INSTANCE_ID" --tags "Key=Name,Value=jaia__CloudHub_VM__${JAIA_CUSTOMER_NAME}"
aws ec2 create-tags --resources "$EIP_ALLOCATION_ID" --tags "Key=Name,Value=jaia__CloudHub_VM__ElasticIP__${JAIA_CUSTOMER_NAME}"
aws ec2 create-tags --resources "$ENI_ID_0" --tags "Key=Name,Value=jaia__CloudHub_VM__NetworkInterface0__${JAIA_CUSTOMER_NAME}"

echo "Tagged resources"

# Wait to get public key
while SERVER_WIREGUARD_PUBKEY=$(ssh -o ConnectTimeout=10 -o PasswordAuthentication=No jaia@${PUBLIC_IPV4_ADDRESS} "sudo cat /etc/wireguard/publickey" || echo Fail); [ "${SERVER_WIREGUARD_PUBKEY}" == "Fail" ]; do
    echo "Waiting for server to startup and first-boot configure to get Wireguard public key";
    sleep 5
done

echo "Server Wireguard Pubkey: ${SERVER_WIREGUARD_PUBKEY}"

aws ec2 revoke-security-group-ingress --group-id "$SECURITY_GROUP_ID" --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0}]',Ipv6Ranges='[{CidrIpv6=::/0}]'
echo "Removed SSH (port 22) on Security Group"

VFLEET_VPN=wg_jaia_vfleet${FLEET_ID}
CLOUD_VPN=wg_jaia_cloud${FLEET_ID}
cat <<EOF >> /tmp/${VFLEET_VPN}.conf
# Write client VPN
[Interface]
# from /etc/wireguard/privatekey on client
PrivateKey = ...

# this client's VPN IP address
Address = ${VIRTUALFLEET_VPN_CLIENT_IPV6}/128

[Peer]
# Server public key (from /etc/wireguard/publickey on server)
PublicKey = ${SERVER_WIREGUARD_PUBKEY}

# Allowed private IPs
AllowedIPs = ${VIRTUALFLEET_VPN_SERVER_IPV6}/48

# Server IP and port
Endpoint = ${PUBLIC_IPV4_ADDRESS}:51820

# Keep connection alive (required for behind NAT routers)
PersistentKeepalive = 52

EOF

cat <<EOF >> /tmp/${CLOUD_VPN}.conf
# Write client VPN
[Interface]
# from /etc/wireguard/privatekey on client
PrivateKey = ...

# this client's VPN IP address
Address = ${CLOUDHUB_VPN_CLIENT_IPV6}/128

[Peer]
# Server public key (from /etc/wireguard/publickey on server)
PublicKey = ${SERVER_WIREGUARD_PUBKEY}

# Allowed private IPs
AllowedIPs = ${CLOUDHUB_VPN_SERVER_IPV6}/48

# Server IP and port
Endpoint = ${PUBLIC_IPV4_ADDRESS}:51821

# Keep connection alive (required for behind NAT routers)
PersistentKeepalive = 52
EOF


echo "SUCCESS: Started CloudHub in Fleet $FLEET_ID:"
echo -e "\tPublic IPv4 address: ${PUBLIC_IPV4_ADDRESS}"


if [[ "$ENABLE_CLIENT_VPN" == "true" ]]; then
    VPN_PRIVATEKEY=$(sudo cat ${VPN_WIREGUARD_PRIVATEKEY_FILE})
    sed -i "s/.*PrivateKey.*/PrivateKey = ${VPN_PRIVATEKEY}/" /tmp/${VFLEET_VPN}.conf
    sed -i "s/.*PrivateKey.*/PrivateKey = ${VPN_PRIVATEKEY}/" /tmp/${CLOUD_VPN}.conf
    sudo mv /tmp/${VFLEET_VPN}.conf /tmp/${CLOUD_VPN}.conf /etc/wireguard
    sudo systemctl enable wg-quick@${VFLEET_VPN}
    sudo systemctl restart wg-quick@${VFLEET_VPN}

    sudo systemctl enable wg-quick@${CLOUD_VPN}
    sudo systemctl restart wg-quick@${CLOUD_VPN}

    echo -e "\tEnabled VPNs:"
    sudo wg show ${VFLEET_VPN}
    sudo wg show ${CLOUD_VPN}

    echo -e "\tLog in with ssh jaia@${VIRTUALFLEET_VPN_SERVER_IPV6}"
else
    echo "Prototype config for VPNs in /tmp/${VFLEET_VPN} and /tmp/${CLOUD_VPN}.conf. You will need to enable one or both VPNs to access the Cloudhub VM."
fi
