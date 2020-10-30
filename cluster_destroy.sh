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

#There's only one of each thing floating around, potentially some compute instances that weren't cleaned up and some images... SO!
OS_PREFIX=${headnode_name}
OS_SSH_SECGROUP_NAME=${OS_PREFIX}-ssh-global
OS_INTERNAL_SECGROUP_NAME=${OS_PREFIX}-internal
OS_SLURM_KEYPAIR=${OS_PREFIX}-slurm-key
OS_ROUTER_NAME=${OS_PREFIX}-elastic-router
OS_SUBNET_NAME=${OS_PREFIX}-elastic-subnet
OS_NETWORK_NAME=${OS_PREFIX}-elastic-net
OS_APP_CRED=${OS_PREFIX}-slurm-app-cred

compute_nodes=$(openstack server list -f value -c Name | grep ${headnode_name}-compute )
if [[ -n "${compute_nodes}" ]]; then
for node in "${compute_nodes}"
do
	echo "Deleting compute node: ${node}"
  openstack server delete ${node}
done
fi

sleep 5 # seems like there are issues with the network deleting correctly 

openstack security group delete ${OS_SSH_SECGROUP_NAME}
openstack security group delete ${OS_INTERNAL_SECGROUP_NAME}
openstack keypair delete ${OS_SLURM_KEYPAIR} # We don't delete the elastic-key, since it could be a user's key used for other stuff
openstack router unset --external-gateway ${OS_ROUTER_NAME}
openstack router remove subnet ${OS_ROUTER_NAME} ${OS_SUBNET_NAME}
openstack router delete ${OS_ROUTER_NAME}
openstack subnet delete ${OS_SUBNET_NAME}
openstack network delete ${OS_NETWORK_NAME}


headnode_images=$(openstack image list --private -f value -c Name | grep ${headnode_name}-compute-image- )
for image in "${headnode_images}"
do
  openstack image delete ${image}
done

openstack application credential delete ${OS_APP_CRED}
