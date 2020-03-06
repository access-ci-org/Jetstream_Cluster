#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

if [[ -z "$1" ]]; then
  echo "NO SERVER NAME GIVEN! Please re-run with ./headnode_create.sh <server-name>"
  exit
fi
server_name=$1

if [[ ! -e ${HOME}/.ssh/id_rsa.pub ]]; then
#This may be temporary... but seems fairly reasonable.
  echo "NO KEY FOUND IN ${HOME}/.ssh/id_rsa.pub! - please create one and re-run!"  
  exit
fi

source ./openrc.sh

# Defining a function here to check for quotas, and exit if this script will cause problems!
# also, storing 'quotas' in a global var, so we're not calling it every single time
quotas=$(openstack quota show)
quota_check () {
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

set -x #show use which commands are executed
set -e #terminate as soon as any command fails

quota_check "secgroups" "security group" 1
quota_check "networks" "network" 1
quota_check "subnets" "subnet" 1
quota_check "routers" "router" 1
quota_check "key-pairs" "keypair" 1
quota_check "instances" "server" 1

# Ensure that the correct private network/router/subnet exists
if [[ -z "$(openstack network list | grep ${server_name}-elastic-net)" ]]; then
  openstack network create ${server_name}-elastic-net
  openstack subnet create --network ${server_name}-elastic-net --subnet-range 10.0.0.0/24 ${server_name}-elastic-subnet1
fi
##openstack subnet list
if [[ -z "$(openstack router list | grep ${server_name}-elastic-router)" ]]; then
  openstack router create ${server_name}-elastic-router
  openstack router add subnet ${server_name}-elastic-router ${server_name}-elastic-subnet1
  openstack router set --external-gateway public ${server_name}-elastic-router
fi

security_groups=$(openstack security group list -f value)
if [[ ! ("$security_groups" =~ "${server_name}-global-ssh") ]]; then
  openstack security group create --description "ssh \& icmp enabled" $server_name-global-ssh
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 $server_name-global-ssh
  openstack security group rule create --protocol icmp $server_name-global-ssh
fi
if [[ ! ("$security_groups" =~ "${server_name}-cluster-internal") ]]; then
  openstack security group create --description "internal group for cluster" $server_name-cluster-internal
  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip 10.0.0.0/0 $server_name-cluster-internal
  openstack security group rule create --protocol icmp $server_name-cluster-internal
fi

#Check if ${HOME}/.ssh/id_rsa.pub exists in JS
if [[ -e ${HOME}/.ssh/id_rsa.pub ]]; then
  home_key_fingerprint=$(ssh-keygen -l -E md5 -f ${HOME}/.ssh/id_rsa.pub | sed  's/.*MD5:\(\S*\) .*/\1/')
fi
openstack_keys=$(openstack keypair list -f value)

home_key_in_OS=$(echo "${openstack_keys}" | awk -v mykey="${home_key_fingerprint}" '$2 ~ mykey {print $1}')

if [[ -n "${home_key_in_OS}" ]]; then
  OS_keyname=${home_key_in_OS}
elif [[ -n $(echo "${openstack_keys}" | grep ${server_name}-elastic-key) ]]; then
  openstack keypair delete ${server_name}-elastic-key
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${server_name}-elastic-key
  OS_keyname=${server_name}-elastic-key
fi

centos_base_image=$(openstack image list --status active | grep -iE "API-Featured-centos7-[[:alpha:]]{3,4}-[0-9]{2}-[0-9]{4}" | awk '{print $4}' | tail -n 1)

openstack server create \
        --user-data prevent-updates.ci \
        --flavor m1.small \
        --image ${centos_base_image} \
        --key-name ${OS_keyname} \
        --security-group ${OS_USERNAME}-global-ssh \
        --security-group ${OS_USERNAME}-cluster-internal \
        --nic net-id=${OS_USERNAME}-elastic-net \
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
