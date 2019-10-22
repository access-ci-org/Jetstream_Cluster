#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

if [[ -z "$1" ]]; then
  echo "NO SERVER NAME GIVEN! Please re-run with ./cluster_destroy.sh <server-name>"
  exit
fi
headnode_name=$1

source ./openrc.sh

headnode_ip=$(openstack server list -f value -c Networks --name ${headnode_name} | sed 's/.*, //')
echo "Removing cluster based on ${headnode_name} at ${headnode_ip}"

openstack server remove floating ip ${headnode_name} ${headnode_ip}
openstack floating ip delete ${headnode_ip}

#os_components=("server" "volume" "router" "subnet" "network" "keypair" "security group")
os_components=("server" "router" "subnet" "network")
for i in `seq 0 $((${#os_components[*]} - 1))`; do # I apologize.
  echo "Removing ${os_components[$i]} for ${headnode_name}:"
  openstack ${os_components[$i]} list -f value -c Name | grep -E "${OS_USERNAME}-elastic"
  particulars=$(openstack ${os_components[$i]} list -f value -c ID -c Name | grep -E "${OS_USERNAME}-elastic" | cut -f 1 -d' ' | tr '\n' ' ') # this should grab head and computes
  if [[ ${os_components[$i]} =~ "server" ]]; then
    echo "Removing headnode: $headnode_name"
    openstack server delete $headnode_name
  fi
  for thing in ${particulars}; do
    if [[ ${os_components[$i]} =~ "router" ]]; then
      openstack router unset --external-gateway ${thing}
      subnet_id=$(openstack router show ${thing} -c interfaces_info -f value | sed 's/\[{"subnet_id": "\([a-zA-Z0-9-]*\)".*/\1/')
      openstack router remove subnet ${thing} ${subnet_id}
      openstack router delete ${thing}
    else
       openstack ${os_components[$i]} delete ${thing}
    fi
  done
done
