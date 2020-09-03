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

openstack server delete ${headnode_name}

openstack floating ip delete ${headnode_ip}

sleep 5 # seems like there are issues with the network deleting correctly 

#There's only one of each thing floating around, potentially some compute instances that weren't cleaned up and some images... SO!
OS_PREFIX=${headnode_name}
OS_SSH_SECGROUP_NAME=${OS_PREFIX}-ssh-global
OS_INTERNAL_SECGROUP_NAME=${OS_PREFIX}-internal
OS_SLURM_KEYPAIR=${OS_PREFIX}-slurm-key
OS_ROUTER_NAME=${OS_PREFIX}-elastic-router
OS_SUBNET_NAME=${OS_PREFIX}-elastic-subnet
OS_NETWORK_NAME=${OS_PREFIX}-elastic-net


openstack security group delete ${OS_SSH_SECGROUP_NAME}
openstack security group delete ${OS_INTERNAL_SECGROUP_NAME}
openstack keypair delete ${OS_SLURM_KEYPAIR} # We don't delete the elastic-key, since it could be a user's key used for other stuff
openstack router unset --external gateway ${OS_ROUTER_NAME}
openstack router remove subnet ${OS_ROUTER_NAME} ${OS_SUBNET_NAME}
openstack router delete ${OS_ROUTER_NAME}
openstack subnet delete ${OS_SUBNET_NAME}
openstack network delete ${OS_NETWORK_NAME}


echo "PLEASE RUN THE FOLLOWING AFTER REVIEWING FOR CORRECTNESS:"
#To avoid namespace collusions where we're only grepping for a name...
# We could also use a regex like ${headnode_name}-compute-[0-9]{2}-[0-9]{2}-[0-9]{4}, thanks to the date convention
# but for now, we'll do the Human-in-The-Loop thing
headnode_images=$(openstack image list --private -f value -c Name | grep ${headnode_name})
for image in "${headnode_images}"
do
  echo "openstack image delete ${image}"
done

compute_nodes=$(openstack server list -f value -c Name | grep ${headnode_name})
for node in "${compute_nodes}"
do
  echo "openstack server delete ${node}"
done

##os_components=("server" "volume" "router" "subnet" "network" "keypair" "security group")
#os_components=("server" "router" "subnet" "network")
#for i in `seq 0 $((${#os_components[*]} - 1))`; do # I apologize.
#  echo "Removing ${os_components[$i]} for ${headnode_name}:"
#  openstack ${os_components[$i]} list -f value -c Name | grep -E ""
#  particulars=$(openstack ${os_components[$i]} list -f value -c ID -c Name | grep -E "${OS_USERNAME}-elastic" | cut -f 1 -d' ' | tr '\n' ' ') # this should grab head and computes
#  if [[ ${os_components[$i]} =~ "server" ]]; then
#    echo "Removing headnode: $headnode_name"
#    openstack server delete $headnode_name
#  fi
#  for thing in ${particulars}; do
#    if [[ ${os_components[$i]} =~ "router" ]]; then
#      openstack router unset --external-gateway ${thing}
#      subnet_id=$(openstack router show ${thing} -c interfaces_info -f value | sed 's/\[{"subnet_id": "\([a-zA-Z0-9-]*\)".*/\1/')
#      openstack router remove subnet ${thing} ${subnet_id}
#      openstack router delete ${thing}
#    else
#       openstack ${os_components[$i]} delete ${thing}
#    fi
#  done
#done
