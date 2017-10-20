#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

if [[ -z "$1" ]]; then
  echo "NO SERVER NAME GIVEN! Please re-run with ./headnode_create.sh <server-name>"
  exit
fi

source ./openrc.sh

# Defining a function here to check for quotas, and exit if this script will cause problems!
# also, storing 'quotas' in a global var, so we're not calling it every single time
quotas=$(openstack quota show)
quota_check () 
{
quota_name=$1
type_name=$2 #the name for a quota and the name for the thing itself are not the same
number_created=$3 #number of the thing that we'll create here.

current_num=$(openstack $type_name list -f value | wc -l)

max_types=$(echo "$quotas" | awk -v quota=$quota_name '$0 ~ quota {print $4}')

#echo "checking quota for $quota_name of $type_name to create $number_created - want $current_num to be less than $max_types"

if [[ "$current_num" -lt "$((max_types + number_created))" ]]; then 
  return 0
fi
return 1
}


quota_check "networks" "network" 1
quota_check "subnets" "subnet" 1
quota_check "routers" "router" 1
quota_check "key-pairs" "keypair" 1
quota_check "instances" "server" 1

# Ensure that the correct private network/router/subnet exists
if [[ -z "$(openstack network list | grep ${OS_USERNAME}-elastic-net)" ]]; then
  openstack network create ${OS_USERNAME}-elastic-net
  openstack subnet create --network ${OS_USERNAME}-elastic-net --subnet-range 10.0.0.0/24 ${OS_USERNAME}-elastic-subnet1
fi
##openstack subnet list
if [[ -z "$(openstack router list | grep ${OS_USERNAME}-elastic-router)" ]]; then
  openstack router create ${OS_USERNAME}-elastic-router
  openstack router add subnet ${OS_USERNAME}-elastic-router ${OS_USERNAME}-elastic-subnet1
  openstack router set --external-gateway public ${OS_USERNAME}-elastic-router
fi
#openstack router show ${OS_USERNAME}-api-router

security_groups=$(openstack security group list -f value)
if [[ ! ("$security_groups" =~ "global-ssh") ]]; then
  openstack security group create --description "ssh \& icmp enabled" global-ssh
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 global-ssh
  openstack security group rule create --protocol icmp global-ssh
fi

#Check if ${HOME}/.ssh/id_rsa.pub exists in JS
if [[ -e ${HOME}/.ssh/id_rsa.pub ]]; then
  home_key_fingerprint=$(ssh-keygen -l -E md5 -f ${HOME}/.ssh/id_rsa.pub | sed  's/.*MD5:\(\S*\) .*/\1/')
fi
openstack_keys=$(openstack keypair list -f value)

home_key_in_OS=$(echo "$openstack_keys" | awk -v mykey=$home_key_fingerprint '$2 ~ mykey {print $1}')

if [[ -n "$home_key_in_OS" ]]; then
  OS_keyname=$home_key_in_OS
elif [[ -n $(echo "$openstack_keys" | grep ${OS_USERNAME}-elastic-key) ]]; then
  openstack keypair delete ${OS_USERNAME}-elastic-key
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_USERNAME}-elastic-key
  OS_keyname=${OS_USERNAME}-elastic-key
else
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_USERNAME}-elastic-key
  OS_keyname=${OS_USERNAME}-elastic-key
fi

openstack server create --flavor m1.small --image "JS-API-Featured-Centos7-Sep-27-2017" --key-name $OS_keyname --security-group global-ssh --security-group cluster-internal --nic net-id=${OS_USERNAME}-elastic-net $1
public_ip=$(openstack floating ip create public | awk '/floating_ip_address/ {print $4}')
openstack server add floating ip $1 $public_ip

echo "You should be able to login to your server with your Jetstream key: $OS_keyname, at $public_ip"
