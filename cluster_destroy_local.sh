#!/bin/bash

set -x

#This script makes several assumptions:
# 1. Running on a host with openstack client tools installed
# 2. Using a default ssh key in ~/.ssh/
# 3. The user knows what they're doing.
# 4. Take some options: 
#    openrc file 
#    cluster name
#    volume size

show_help() {
  echo "Options:
        HEADNODE_NAME: required, name of the cluster to delete
        OPENRC_PATH: optional, path to a valid openrc file, defaults to ~/openrc.sh
        VOLUME_DELETE: optional flag, set to delete storage volumes, default false
  
Usage: $0 -n <HEADNODE_NAME> -o [OPENRC_PATH] [-v] "
}

OPTIND=1

openrc_path="${HOME}/openrc.sh"
headnode_name="$(hostname --short)"
volume_delete="0"

while getopts ":hhelp:o:n:v" opt; do
  case ${opt} in
    h|help|\?) show_help
      exit 0
      ;;
    o) openrc_path=${OPTARG}
      ;;
    n) headnode_name=${OPTARG}
      ;;
    v) volume_delete=1
      ;;
    :) echo "Option -$OPTARG requires an argument."
      exit 1
      ;;

  esac
done


if [[ ! -f ${openrc_path} ]]; then
  echo "openrc path: ${openrc_path} \n does not point to a file!"
  exit 1
elif [[ "${volume_delete}" != "0" && "${volume_delete}" != "1" ]]; then
  echo "Volume_delete parameter must be 0 or 1 instead of ${volume_delete}"
  exit 1
fi

source ${openrc_path}

#There's only one of each thing floating around, potentially some compute instances that weren't cleaned up and some images... SO!
OS_PREFIX=${headnode_name}
OS_SSH_SECGROUP_NAME=${OS_PREFIX}-ssh-global
OS_INTERNAL_SECGROUP_NAME=${OS_PREFIX}-internal
OS_SLURM_KEYPAIR=${OS_PREFIX}-slurm-key
OS_KEYPAIR_NAME=${OS_PREFIX}-elastic-key
OS_ROUTER_NAME=${OS_PREFIX}-elastic-router
OS_SUBNET_NAME=${OS_PREFIX}-elastic-subnet
OS_NETWORK_NAME=${OS_PREFIX}-elastic-net

compute_nodes=$(openstack server list -f value -c Name | grep -E "compute-${headnode_name}-base-instance|${headnode_name}-compute" )
if [[ -n "${compute_nodes}" ]]; then
for node in "${compute_nodes}"
do
	echo "Deleting compute node: ${node}"
  openstack server delete ${node}
done
fi

sleep 5 # seems like there are issues with the network deleting correctly 

SERVER_UUID=$(curl http://169.254.169.254/openstack/latest/meta_data.json | jq '.uuid' | sed -e 's#"##g')

openstack server remove security group ${SERVER_UUID} ${OS_SSH_SECGROUP_NAME} || true
openstack server remove security group ${SERVER_UUID} ${OS_INTERNAL_SECGROUP_NAME} || true
openstack server remove network ${SERVER_UUID} ${OS_NETWORK_NAME}

openstack security group delete ${OS_SSH_SECGROUP_NAME}
openstack security group delete ${OS_INTERNAL_SECGROUP_NAME}
openstack keypair delete ${OS_SLURM_KEYPAIR}
# We DO delete the elastic-key, since we created it from scratch before
openstack keypair delete ${OS_KEYPAIR_NAME}
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
