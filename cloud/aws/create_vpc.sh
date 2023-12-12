#!/bin/bash
set -u -e

# Check if necessary parameters are provided
if (( "$#" != 1 )); then
    echo "Usage: $0 vpc.conf"
    exit 1
fi

handle_failure() {
    echo "FAILURE"
    exit 1
}
trap handle_failure ERR

# Runs an AWS command, optionally displays the output if DEBUG=true, and returns a jq filter if set
function run() {
    # $1: jq filter
    # ${@:2}: AWS CLI command
    
    # Execute the AWS CLI command and capture the output
    local aws_command_output
    echo "" >&2
    aws_command_output=$(set -x; "${@:2}" --output json)
    result=$?

    if [[ "$DEBUG" = "true" ]]; then
        # Display the full output in compact form
        echo "$aws_command_output" | jq -c . >&2
    fi

    if [ ! -z "$1" ]; then
       # Apply the jq filter and return the result
       local filtered_output
       filtered_output=$(echo "$aws_command_output" | jq -r "$1")
       echo "$filtered_output"
    fi

    if [[ "$result" = "0" ]]; then
        echo "OK" >&2
    fi
    echo "" >&2
    
    return $result
}

set -a
source $1
set +a

SCRIPT_PATH=$(dirname "$0")
FLEET_ID_HEX=$(printf '%x\n' ${FLEET_ID})
VPC_CIDR_BLOCK="10.23.0.0/16"
# maps onto real fleet IP assignment
WLAN_CIDR_BLOCK="10.23.${FLEET_ID}.0/24"
CLOUDHUB_ID=30
CLOUDHUB_WLAN_IP_ADDRESS="10.23.${FLEET_ID}.$((CLOUDHUB_ID+10))"
# IPv6 address to use for VirtualFleet VPN (fd6e:cf0d:aefa:FLEET_ID_HEX::/48)
VIRTUALFLEET_VPN_SERVER_CIDR_48="fd6e:cf0d:aefa"
VIRTUALFLEET_VPN_SERVER_CIDR_64="${VIRTUALFLEET_VPN_SERVER_CIDR_48}:${FLEET_ID_HEX}"
VIRTUALFLEET_VPN_CLIENT_IPV6="${VIRTUALFLEET_VPN_SERVER_CIDR_64}::2:1"
VIRTUALFLEET_VPN_SERVER_IPV6="${VIRTUALFLEET_VPN_SERVER_CIDR_64}::0:30"
# IPv6 address to use for VirtualFleet VPN (fd0f:77ac:4fdf:FLEET_ID_HEX::/48)
CLOUDHUB_VPN_SERVER_CIDR_48="fd0f:77ac:4fdf"
CLOUDHUB_VPN_SERVER_CIDR_64="${CLOUDHUB_VPN_SERVER_CIDR_48}:${FLEET_ID_HEX}"
CLOUDHUB_VPN_CLIENT_IPV6="${CLOUDHUB_VPN_SERVER_CIDR_64}::2:1"
CLOUDHUB_VPN_SERVER_IPV6="${CLOUDHUB_VPN_SERVER_CIDR_64}::0:30"
# generate Wireguard keys
VPN_WIREGUARD_PRIVATEKEY=$(wg genkey)
VPN_WIREGUARD_PUBKEY=$(echo $VPN_WIREGUARD_PRIVATEKEY | wg pubkey)

export AWS_DEFAULT_REGION=$REGION
ACCOUNT_ID=$(run ".Account" aws sts get-caller-identity)



# Create a VPC
VPC_ID=$(run ".Vpc.VpcId" aws ec2 create-vpc --cidr-block "$VPC_CIDR_BLOCK" --amazon-provided-ipv6-cidr-block)
echo ">>>>>> Created VPC with ID: $VPC_ID"

VPC_IPV6_BLOCK=$(run ".Vpcs[].Ipv6CidrBlockAssociationSet[].Ipv6CidrBlock" aws ec2 describe-vpcs --vpc-id ${VPC_ID})
echo ">>>>>> Created VPC IPV6 block: $VPC_IPV6_BLOCK"

# Create Policy for CloudHub to manage VirtualFleet instances
POLICY_FILE_IN="${SCRIPT_PATH}/cloudhub-iam-policy.json.in"
POLICY_FILE="/tmp/cloudhub-iam-policy.json"

cp ${POLICY_FILE_IN} ${POLICY_FILE}
sed -i "s/{{REGION}}/${REGION}/g" ${POLICY_FILE}
sed -i "s/{{ACCOUNT_ID}}/${ACCOUNT_ID}/g" ${POLICY_FILE}
sed -i "s/{{VPC_ID}}/${VPC_ID}/g" ${POLICY_FILE}

role_name="JaiaCloudHubFleet${FLEET_ID}__Role"
policy_name="JaiaCloudHubFleet${FLEET_ID}__Policy"
instance_profile_name="JaiaCloudHubFleet${FLEET_ID}__InstanceProfile"

echo ">>>>>> Checking if Instance Profile exists (NoSuchEntity errors are OK)"

if run "" aws iam get-instance-profile --instance-profile-name $instance_profile_name; then
    echo ">>>>>> Instance profile already exists. Deleting."
    run "" aws iam remove-role-from-instance-profile --instance-profile-name $instance_profile_name --role-name $role_name || true
    run "" aws iam delete-instance-profile --instance-profile-name $instance_profile_name
fi

echo ">>>>>> Checking if Role exists (NoSuchEntity errors are OK)"

if run "" aws iam get-role --role-name $role_name; then
    echo ">>>>>> Role already exists. Deleting."
    run "" aws iam delete-role-policy --role-name $role_name --policy-name $policy_name || true
    run "" aws iam delete-role --role-name $role_name
fi

echo ">>>>>> Creating role."
run "" aws iam create-role --role-name $role_name --assume-role-policy-document file://cloudhub-trust-policy.json
run "" aws iam put-role-policy --role-name $role_name --policy-name $policy_name --policy-document file://${POLICY_FILE}

echo ">>>>>> Creating instance profile."
run "" aws iam create-instance-profile --instance-profile-name $instance_profile_name
run "" aws iam add-role-to-instance-profile --instance-profile-name $instance_profile_name --role-name $role_name

# Create an Internet Gateway
INTERNET_GATEWAY_ID=$(run ".InternetGateway.InternetGatewayId" aws ec2 create-internet-gateway)
echo ">>>>>> Created Internet Gateway with ID: $INTERNET_GATEWAY_ID"

# Attach the Internet Gateway to the VPC
run "" aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $INTERNET_GATEWAY_ID
echo ">>>>>> Attached Internet Gateway to VPC"

# Create two subnets: 1) Cloudhub where eth0 which has the same IPv4 assignment as wlan0 in the real fleet, plus an IPv6 block and 2) VirtualFleet with just an IPv6 block
SUBNET_CLOUDHUB_IPV6=$(echo ${VPC_IPV6_BLOCK} | sed 's|00::/56|00::/64|')
SUBNET_CLOUDHUB_ID=$(run ".Subnet.SubnetId" aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $WLAN_CIDR_BLOCK --ipv6-cidr-block $SUBNET_CLOUDHUB_IPV6 )
echo ">>>>>> Created CloudHub Subnet with ID: $SUBNET_CLOUDHUB_ID and IPv6: ${SUBNET_CLOUDHUB_IPV6}"
run "" aws ec2 modify-subnet-attribute --assign-ipv6-address-on-creation --subnet-id ${SUBNET_CLOUDHUB_ID}

SUBNET_VIRTUALFLEET_IPV6=$(echo ${VPC_IPV6_BLOCK} | sed 's|00::/56|01::/64|')
SUBNET_VIRTUALFLEET_ID=$(run ".Subnet.SubnetId" aws ec2 create-subnet --vpc-id $VPC_ID --ipv6-native --ipv6-cidr-block $SUBNET_VIRTUALFLEET_IPV6)
echo ">>>>>> Created VirtualFleet Subnet with ID: $SUBNET_VIRTUALFLEET_ID and IPv6: ${SUBNET_VIRTUALFLEET_IPV6}"
run "" aws ec2 modify-subnet-attribute --assign-ipv6-address-on-creation --subnet-id ${SUBNET_VIRTUALFLEET_ID}

# Create a Security Group
SECURITY_GROUP_ID=$(run '.GroupId' aws ec2 create-security-group --group-name "jaia__SecurityGroup__${JAIA_CUSTOMER_NAME}" --description "jaia__${JAIA_CUSTOMER_NAME} Security Group" --vpc-id $VPC_ID)
echo ">>>>>> Created Security Group with ID: $SECURITY_GROUP_ID"

# Set Up Security Group Rules
run "" aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0}]',Ipv6Ranges='[{CidrIpv6=::/0}]'
echo ">>>>>> Allowed SSH (port 22) on Security Group"

run "" aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --ip-permissions IpProtocol=udp,FromPort=51820,ToPort=51821,IpRanges='[{CidrIp=0.0.0.0/0}]',Ipv6Ranges='[{CidrIpv6=::/0}]'
echo ">>>>>> Allowed UDP ports 51820-51821 (Wireguard) on Security Group"


# Modify the Main Route Table to use the Internet Gateway
ROUTE_TABLE_ID=$(run  '.RouteTables[0].RouteTableId' aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true")
run "" aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $INTERNET_GATEWAY_ID
run "" aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-ipv6-cidr-block ::/0 --gateway-id $INTERNET_GATEWAY_ID
echo ">>>>>> Modified the main route table to use the Internet Gateway"

## Launch the actual VM (CloudHub)
USER_DATA_FILE_IN="${SCRIPT_PATH}/cloud-init-user-data.sh.in"
USER_DATA_FILE="/tmp/cloud-init-user-data.sh"
DISK_SIZE_GB=32

# replace some {{MACROS}} in the user data
cp ${USER_DATA_FILE_IN} ${USER_DATA_FILE}
sed -i "s/{{FLEET_ID}}/${FLEET_ID}/g" ${USER_DATA_FILE}

# Replace newlines in the variable with a unique pattern, e.g., '|||'
FORMATTED_SSH_KEYS=$(echo "$SSH_PUBKEYS" | sed ':a;N;$!ba;s/\n/|||/g')
# Use 'sed' to replace the placeholder with the formatted keys
sed -i "s\\{{SSH_PUBKEYS}}\\$FORMATTED_SSH_KEYS\\" ${USER_DATA_FILE}
# Restore the newlines in the file
sed -i 's/|||/\n/g' ${USER_DATA_FILE}

sed -i "s/{{CLOUDHUB_ID}}/${CLOUDHUB_ID}/g" ${USER_DATA_FILE}
sed -i "s|{{VPN_WIREGUARD_PUBKEY}}|${VPN_WIREGUARD_PUBKEY}|g" ${USER_DATA_FILE}
sed -i "s/{{VIRTUALFLEET_VPN_CLIENT_IPV6}}/${VIRTUALFLEET_VPN_CLIENT_IPV6}/g" ${USER_DATA_FILE}
sed -i "s/{{VIRTUALFLEET_VPN_SERVER_IPV6}}/${VIRTUALFLEET_VPN_SERVER_IPV6}/g" ${USER_DATA_FILE}
sed -i "s/{{CLOUDHUB_VPN_CLIENT_IPV6}}/${CLOUDHUB_VPN_CLIENT_IPV6}/g" ${USER_DATA_FILE}
sed -i "s/{{CLOUDHUB_VPN_SERVER_IPV6}}/${CLOUDHUB_VPN_SERVER_IPV6}/g" ${USER_DATA_FILE}

# Find the newest AMI matching the tags
AMI_ID=$(run " " aws ec2 describe-images --filters "Name=tag:jaiabot-rootfs-gen_repository,Values=${REPO}" "Name=tag:jaiabot-rootfs-gen_repository_version,Values=${REPO_VERSION}" --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId')

if [ "$AMI_ID" == "None" ]; then
    echo ">>>>>> No matching AMI found for repo: ${REPO} and version: ${REPO_VERSION}. Available AMIs include: "
    run "" aws ec2 describe-images --filters "Name=tag:jaiabot-rootfs-gen_repository,Values=*"
    exit 1
fi

echo ">>>>>> Newest matching AMI ID: $AMI_ID"

block_device_mappings_json=$(jq -n -c \
                  --arg volSize "$DISK_SIZE_GB" \
                  --arg volType "gp3" \
                  '[
                     {
                       "DeviceName": "/dev/sda1",
                       "Ebs": {
                         "VolumeSize": ($volSize | tonumber),
                         "VolumeType": $volType
                       }
                     }
                   ]')

# Construct the network interfaces JSON using jq
network_interfaces_json=$(jq -n -c \
                  --arg subnetId "$SUBNET_CLOUDHUB_ID" \
                  --arg privateIp "$CLOUDHUB_WLAN_IP_ADDRESS" \
                  --arg groupId "$SECURITY_GROUP_ID" \
                  '[
                     {
                       "DeviceIndex": 0,
                       "DeleteOnTermination": true,
                       "SubnetId": $subnetId,
                       "PrivateIpAddress": $privateIp,
                       "Groups": [$groupId]
                     }
                   ]')


# Launch the EC2 instance w/ two network interfaces
INSTANCE_ID=$(run ".Instances[0].InstanceId" aws ec2 run-instances \
                    --image-id "$AMI_ID" \
                    --instance-type "$INSTANCE_TYPE" \
                    --block-device-mappings "$block_device_mappings_json" \
                    --user-data file://"$USER_DATA_FILE" \
                    --network-interfaces "$network_interfaces_json" \
                    --iam-instance-profile "Name=$instance_profile_name")

echo ">>>>>> EC2 Instance launched successfully with ID: $INSTANCE_ID"

# Wait for the instance to be in a running state
echo ">>>>>> Waiting for instance to be in 'running' state..."
while state=$(run '.Reservations[].Instances[].State.Name' aws ec2 describe-instances --instance-ids $INSTANCE_ID); [ "$state" != "running" ]; do
  sleep 5
  echo ">>>>>> Instance state: $state"
done

ENI_ID_0=$(run ".NetworkInterfaces[0].NetworkInterfaceId" aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" "Name=attachment.device-index,Values=0")
echo ">>>>>> ENI ID: $ENI_ID_0"

# Allocate an Elastic IP Address
EIP_ALLOCATION_ID=$(run '.AllocationId' aws ec2 allocate-address)
echo ">>>>>> Allocated Elastic IP Address with Allocation ID: $EIP_ALLOCATION_ID"

PUBLIC_IPV4_ADDRESS=$(run ".Addresses[0].PublicIp" aws ec2 describe-addresses --allocation-ids $EIP_ALLOCATION_ID)

echo ">>>>>> Instance is running. Proceeding to associate Elastic IP Address."

# Associate the Elastic IP Address with the EC2 Instance
run "" aws ec2 associate-address --network-interface-id $ENI_ID_0 --allocation-id $EIP_ALLOCATION_ID
echo ">>>>>> Associated Elastic IP Address with EC2 Instance"

# Tag the Resources
run "" aws ec2 create-tags --resources "$VPC_ID" "$SUBNET_CLOUDHUB_ID" "$SUBNET_VIRTUALFLEET_ID" "$SECURITY_GROUP_ID" "$INTERNET_GATEWAY_ID" "$INSTANCE_ID" "$ROUTE_TABLE_ID" "$EIP_ALLOCATION_ID" "$ENI_ID_0" --tags "Key=jaia_customer,Value=${JAIA_CUSTOMER_NAME}" "Key=jaia_fleet,Value=${FLEET_ID}" "Key=jaiabot-rootfs-gen_repository,Value=${REPO}" "Key=jaiabot-rootfs-gen_repository_version,Value=${REPO_VERSION}"

run "" aws ec2 create-tags --resources "$VPC_ID"  --tags "Key=Name,Value=jaia__VPC__${JAIA_CUSTOMER_NAME}"
run "" aws ec2 create-tags --resources "$SUBNET_CLOUDHUB_ID"  --tags "Key=Name,Value=jaia__Subnet_CloudHub__${JAIA_CUSTOMER_NAME}"
run "" aws ec2 create-tags --resources "$SUBNET_VIRTUALFLEET_ID"  --tags "Key=Name,Value=jaia__Subnet_VirtualFleet__${JAIA_CUSTOMER_NAME}"
run "" aws ec2 create-tags --resources "$SECURITY_GROUP_ID"  --tags "Key=Name,Value=jaia__SecurityGroup__${JAIA_CUSTOMER_NAME}"
run "" aws ec2 create-tags --resources "$INTERNET_GATEWAY_ID"  --tags "Key=Name,Value=jaia__InternetGateway__${JAIA_CUSTOMER_NAME}"
run "" aws ec2 create-tags --resources "$ROUTE_TABLE_ID"  --tags "Key=Name,Value=jaia__RouteTable__${JAIA_CUSTOMER_NAME}"

# VM specific
run "" aws ec2 create-tags --resources "$INSTANCE_ID" --tags "Key=Name,Value=jaia__CloudHub_VM__${JAIA_CUSTOMER_NAME}" "Key=jaia_instance_type,Value=cloudhub"
run "" aws ec2 create-tags --resources "$EIP_ALLOCATION_ID" --tags "Key=Name,Value=jaia__CloudHub_VM__ElasticIP__${JAIA_CUSTOMER_NAME}"
run "" aws ec2 create-tags --resources "$ENI_ID_0" --tags "Key=Name,Value=jaia__CloudHub_VM__NetworkInterface0__${JAIA_CUSTOMER_NAME}"

echo ">>>>>> Tagged resources"

# Wait to get public key
while SERVER_WIREGUARD_PUBKEY=$(ssh -o ConnectTimeout=10 -o PasswordAuthentication=No jaia@${PUBLIC_IPV4_ADDRESS} "sudo cat /etc/wireguard/publickey" || echo Fail); [ "${SERVER_WIREGUARD_PUBKEY}" == "Fail" ]; do
    echo ">>>>>> Waiting for server to startup and first-boot configure to get Wireguard public key";
    sleep 5
done

echo ">>>>>> Server Wireguard Pubkey: ${SERVER_WIREGUARD_PUBKEY}"

run "" aws ec2 revoke-security-group-ingress --group-id $SECURITY_GROUP_ID --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0}]',Ipv6Ranges='[{CidrIpv6=::/0}]'
echo ">>>>>> Removed SSH (port 22) on Security Group"

VFLEET_VPN=wg_jaia_vfleet${FLEET_ID}
CLOUD_VPN=wg_jaia_cloud${FLEET_ID}
cat <<EOF > /tmp/${VFLEET_VPN}.conf
[Interface]
# from /etc/wireguard/privatekey on client
PrivateKey = ...

# this client's VPN IP address
Address = ${VIRTUALFLEET_VPN_CLIENT_IPV6}/128

[Peer]
# Server public key (from /etc/wireguard/publickey on server)
PublicKey = ${SERVER_WIREGUARD_PUBKEY}

# Allowed private IPs
AllowedIPs = ${VIRTUALFLEET_VPN_SERVER_CIDR_48}::/48

# Server IP and port
Endpoint = ${PUBLIC_IPV4_ADDRESS}:51820

# Keep connection alive (required for behind NAT routers)
PersistentKeepalive = 52

EOF

cat <<EOF > /tmp/${CLOUD_VPN}.conf
[Interface]
# from /etc/wireguard/privatekey on client
PrivateKey = ...

# this client's VPN IP address
Address = ${CLOUDHUB_VPN_CLIENT_IPV6}/128

[Peer]
# Server public key (from /etc/wireguard/publickey on server)
PublicKey = ${SERVER_WIREGUARD_PUBKEY}

# Allowed private IPs
AllowedIPs = ${CLOUDHUB_VPN_SERVER_CIDR_48}::/48

# Server IP and port
Endpoint = ${PUBLIC_IPV4_ADDRESS}:51821

# Keep connection alive (required for behind NAT routers)
PersistentKeepalive = 52
EOF


echo ">>>>>> Started CloudHub in Fleet $FLEET_ID:"
echo ">>>>>> Public IPv4 address: ${PUBLIC_IPV4_ADDRESS}"


if [[ "$ENABLE_CLIENT_VPN" == "true" ]]; then
    sed -i "s|.*PrivateKey.*|PrivateKey = ${VPN_WIREGUARD_PRIVATEKEY}|" /tmp/${VFLEET_VPN}.conf
    sed -i "s|.*PrivateKey.*|PrivateKey = ${VPN_WIREGUARD_PRIVATEKEY}|" /tmp/${CLOUD_VPN}.conf
    sudo mv /tmp/${VFLEET_VPN}.conf /tmp/${CLOUD_VPN}.conf /etc/wireguard
    sudo systemctl enable wg-quick@${VFLEET_VPN}
    sudo systemctl restart wg-quick@${VFLEET_VPN}

    sudo systemctl enable wg-quick@${CLOUD_VPN}
    sudo systemctl restart wg-quick@${CLOUD_VPN}

    echo ">>>>>> Enabled VPNs:"
    sudo wg show ${VFLEET_VPN}
    sudo wg show ${CLOUD_VPN}
    while ! ping6 -c 1 "${CLOUDHUB_VPN_SERVER_IPV6}" &> /dev/null
    do
        echo ">>>>>> Waiting for CloudHub (${CLOUDHUB_VPN_SERVER_IPV6}) to respond..."
        sleep 1
    done
    echo ">>>>>> Ping successful!"

    # remove old ssh host info (if any)
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R ${CLOUDHUB_VPN_SERVER_IPV6} || true
    
    echo ">>>>>> Log in with ssh jaia@${CLOUDHUB_VPN_SERVER_IPV6}"
    ssh jaia@${CLOUDHUB_VPN_SERVER_IPV6}
else
    echo ">>>>>> Prototype config for VPNs in /tmp/${VFLEET_VPN} and /tmp/${CLOUD_VPN}.conf. You will need to enable one or both VPNs to access the Cloudhub VM."
fi

echo ">>>>>> SUCCESS"
