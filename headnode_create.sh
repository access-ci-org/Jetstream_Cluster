#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

if [[ -z "$1" ]]; then
  echo "NO SERVER NAME GIVEN! Please re-run with ./headnode_create.sh <server-name>"
  exit
fi

if [[ ! -e ${HOME}/.ssh/id_rsa.pub ]]; then
#This may be temporary... but seems fairly reasonable.
  echo "NO KEY FOUND IN ${HOME}/.ssh/id_rsa.pub! - please create one and re-run!"  
  exit
fi

server_name=$1
source ./openrc.sh

# Defining a function here to check for quotas, and exit if this script will cause problems!
# also, storing 'quotas' in a global var, so we're not calling it every single time
quotas=$(openstack quota show)
quota_check () 
{
quota_name=$1
type_name=$2 #the name for a quota and the name for the thing itself are not the same
number_created=$3 #number of the thing that we'll create here.

current_num=$(openstack ${type_name} list -f value | wc -l)

max_types=$(echo "${quotas}" | awk -v quota=${quota_name} '$0 ~ quota {print $4}')

#echo "checking quota for ${quota_name} of ${type_name} to create ${number_created} - want ${current_num} to be less than ${max_types}"

if [[ "${current_num}" -lt "$((max_types + number_created))" ]]; then 
  return 0
fi
return 1
}


quota_check "secgroups" "security group" 1
quota_check "networks" "network" 1
quota_check "subnets" "subnet" 1
quota_check "routers" "router" 1
quota_check "key-pairs" "keypair" 1
quota_check "instances" "server" 1

OS_PREFIX=${server_name}
OS_NETWORK_NAME=${OS_PREFIX}-elastic-net
OS_SUBNET_NAME=${OS_PREFIX}-elastic-subnet
OS_ROUTER_NAME=${OS_PREFIX}-elastic-router
OS_SSH_SECGROUP_NAME=${OS_PREFIX}-ssh-global
OS_INTERNAL_SECGROUP_NAME=${OS_PREFIX}-internal
OS_KEYPAIR_NAME=${OS_USERNAME}-elastic-key


# Ensure that the correct private network/router/subnet exists
if [[ -z "$(openstack network list | grep ${OS_NETWORK_NAME})" ]]; then
  openstack network create ${OS_NETWORK_NAME}
  openstack subnet create --network ${OS_NETWORK_NAME} --subnet-range 10.0.0.0/24 ${OS_SUBNET_NAME}
fi
##openstack subnet list
if [[ -z "$(openstack router list | grep ${OS_ROUTER_NAME})" ]]; then
  openstack router create ${OS_ROUTER_NAME}
  openstack router add subnet ${OS_ROUTER_NAME} ${OS_SUBNET_NAME}
  openstack router set --external-gateway public ${OS_ROUTER_NAME}
fi
#openstack router show ${OS_ROUTER_NAME}

security_groups=$(openstack security group list -f value)
if [[ ! ("${security_groups}" =~ "${OS_SSH_SECGROUP_NAME}") ]]; then
  openstack security group create --description "ssh \& icmp enabled" ${OS_SSH_SECGROUP_NAME}
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 ${OS_SSH_SECGROUP_NAME}
  openstack security group rule create --protocol icmp ${OS_SSH_SECGROUP_NAME}
fi
if [[ ! ("${security_groups}" =~ "${OS_INTERNAL_SECGROUP_NAME}") ]]; then
  openstack security group create --description "internal group for cluster" ${OS_INTERNAL_SECGROUP_NAME}
  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip 10.0.0.0/24 ${OS_INTERNAL_SECGROUP_NAME}
  openstack security group rule create --protocol icmp ${OS_INTERNAL_SECGROUP_NAME}
fi

#Check if ${HOME}/.ssh/id_rsa.pub exists in JS
if [[ -e ${HOME}/.ssh/id_rsa.pub ]]; then
  home_key_fingerprint=$(ssh-keygen -l -E md5 -f ${HOME}/.ssh/id_rsa.pub | sed  's/.*MD5:\(\S*\) .*/\1/')
fi
openstack_keys=$(openstack keypair list -f value)

home_key_in_OS=$(echo "${openstack_keys}" | awk -v mykey="${home_key_fingerprint}" '$2 ~ mykey {print $1}')

if [[ -n "${home_key_in_OS}" ]]; then
  OS_KEYPAIR_NAME=${home_key_in_OS}
elif [[ -n $(echo "${openstack_keys}" | grep ${OS_KEYPAIR_NAME}) ]]; then
  openstack keypair delete ${OS_KEYPAIR_NAME}
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_KEYPAIR_NAME}
else
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_KEYPAIR_NAME}
fi

#centos_base_image=$(openstack image list --status active | grep -iE "API-Featured-centos7-[[:alpha:]]{3,4}-[0-9]{2}-[0-9]{4}" | awk '{print $4}' | tail -n 1)
centos_base_image="JS-API-Featured-CentOS7-Latest"

echo -e "openstack server create\
        --user-data prevent-updates.ci \
        --flavor m1.small \
        --image ${centos_base_image} \
        --key-name ${OS_KEYPAIR_NAME} \
        --security-group ${OS_SSH_SECGROUP_NAME} \
        --security-group ${OS_INTERNAL_SECGROUP_NAME} \
        --nic net-id=${OS_NETWORK_NAME} \
        ${server_name}"

openstack server create \
        --user-data prevent-updates.ci \
        --flavor m1.small \
        --image ${centos_base_image} \
        --key-name ${OS_KEYPAIR_NAME} \
        --security-group ${OS_SSH_SECGROUP_NAME} \
        --security-group ${OS_INTERNAL_SECGROUP_NAME} \
        --nic net-id=${OS_NETWORK_NAME} \
        ${server_name}

public_ip=$(openstack floating ip create public | awk '/floating_ip_address/ {print $4}')
#For some reason there's a time issue here - adding a sleep command to allow network to become ready
sleep 10
openstack server add floating ip ${server_name} ${public_ip}

hostname_test=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname')
echo "test1: ${hostname_test}"
until [[ ${hostname_test} =~ "${server_name}" ]]; do
  sleep 2
  hostname_test=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname')
  echo "ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname'"
  echo "test2: ${hostname_test}"
done

scp -qr -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${PWD} centos@${public_ip}:

echo "You should be able to login to your server with your Jetstream key: ${OS_keyname}, at ${public_ip}"
