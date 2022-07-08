#!/bin/bash

# Uncomment below to help with debugging
set -x

#This script makes several assumptions:
# 1. Running on a host with openstack client tools installed
# 2. Using a default ssh key in ~/.ssh/
# 3. The user knows what they're doing.
# 4. Take some options:
#    openrc file
#    volume size

show_help() {
  echo "Options:
        -o: OPENRC_PATH: optional, path to a valid openrc file, default is ~/openrc.sh
        -v: VOLUME_SIZE: optional, size of storage volume in GB, volume not created if 0
        -d: DOCKER_ALLOW: optional flag, leave docker installed on headnode if set.
	-j: JUPYTERHUB_BUILD: optional flag, install jupyterhub with SSL certs.

Usage: $0 -o [OPENRC_PATH] -v [VOLUME_SIZE] [-d]"
}

OPTIND=1

openrc_path="${HOME}/openrc.sh"
volume_size="0"
install_opts=""

while getopts ":jdhhelp:n:o:s:v:" opt; do
  case ${opt} in
    h|help|\?) show_help
      exit 0
      ;;
    d) install_opts+="-d "
      ;;
    j) install_opts+="-j "
      ;;
    o) openrc_path=${OPTARG}
      ;;
    v) volume_size=${OPTARG}
      ;;
    :) echo "Option -$OPTARG requires an argument."
      exit 1
      ;;

  esac
done

sudo pip3 install openstacksdk==0.61.0
sudo pip3 install python-openstackclient
sudo ln -s /usr/local/bin/openstack /usr/bin/openstack

if [[ ! -f ${openrc_path} ]]; then
  echo "openrc path: ${openrc_path} \n does not point to a file!"
  exit 1
fi

headnode_name="$(hostname --short)"

#Move this to allow for error checking of OS conflicts
source ${openrc_path}

if [[ -n "$(echo ${volume_size} | tr -d [0-9])" ]]; then
  echo "Volume size must be numeric only, in units of GB."
  exit 1
elif [[ -n $(openstack volume list | grep -i ${headnode_name}-storage) ]]; then
  echo "Volume name [${headnode_name}-storage] conficts with existing Openstack entity!" 
  exit 1
fi

if [[ ! -e ${HOME}/.ssh/id_rsa.pub ]]; then
  ssh-keygen -q -N "" -f ${HOME}/.ssh/id_rsa
fi

volume_name="${headnode_name}-storage"

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

#These must match those defined in install.sh, slurm_resume.sh, compute_build_base_img.yml
#  and compute_take_snapshot.sh, which ASSUME the headnode_name convention has not been deviated from.

OS_PREFIX=${headnode_name}
OS_SSH_SECGROUP_NAME=${OS_PREFIX}-ssh-global
OS_INTERNAL_SECGROUP_NAME=${OS_PREFIX}-internal
OS_HTTP_S_SECGROUP_NAME=${OS_PREFIX}-http-s
OS_KEYPAIR_NAME=${OS_PREFIX}-elastic-key

HEADNODE_NETWORK=$(openstack server show $(hostname -s) | grep addresses | awk  -F'|' '{print $3}' | awk -F'=' '{print $1}'  | awk '{$1=$1};1')
HEADNODE_IP=$(openstack server show $(hostname -s) | grep addresses | awk  -F'|' '{print $3}' | awk  -F'=' '{print $2}' | awk  -F',' '{print $1}')
SUBNET=$(ip addr | grep $HEADNODE_IP | awk '{print $2}')

echo "Headnode network name ${HEADNODE_NETWORK}"
echo "Headnode ip ${HEADNODE_IP}"
echo "Subnet ${SUBNET}"

# This will allow for customization of the 1st 24 bits of the subnet range
# The last 8 will be assumed open (netmask 255.255.255.0 or /24)
# because going beyond that requires a general mechanism for translation from CIDR
# to wildcard notation for ssh.cfg and compute_build_base_img.yml
# which is assumed to be beyond the scope of this project.
#  If there is a maintainable mechanism for this, of course, please let us know!

security_groups=$(openstack security group list -f value)
if [[ ! ("${security_groups}" =~ "${OS_SSH_SECGROUP_NAME}") ]]; then
  openstack security group create --description "ssh \& icmp enabled" ${OS_SSH_SECGROUP_NAME}
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 ${OS_SSH_SECGROUP_NAME}
  openstack security group rule create --protocol icmp ${OS_SSH_SECGROUP_NAME}
fi
if [[ ! ("${security_groups}" =~ "${OS_INTERNAL_SECGROUP_NAME}") ]]; then
  openstack security group create --description "internal group for cluster" ${OS_INTERNAL_SECGROUP_NAME}
  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip ${SUBNET} ${OS_INTERNAL_SECGROUP_NAME}
  openstack security group rule create --protocol icmp ${OS_INTERNAL_SECGROUP_NAME}
fi
if [[ (! ("${security_groups}" =~ "${OS_HTTP_S_SECGROUP_NAME}")) && "${install_opts}" =~ "j" ]]; then
  openstack security group create --description "http/s for jupyterhub" ${OS_HTTP_S_SECGROUP_NAME}
  openstack security group rule create --protocol tcp --dst-port 80 --remote-ip 0.0.0.0/0 ${OS_HTTP_S_SECGROUP_NAME}
  openstack security group rule create --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0 ${OS_HTTP_S_SECGROUP_NAME}
fi

#Check if ${HOME}/.ssh/id_rsa.pub exists in JS
if [[ -e ${HOME}/.ssh/id_rsa.pub ]]; then
  home_key_fingerprint=$(ssh-keygen -l -E md5 -f ${HOME}/.ssh/id_rsa.pub | sed  's/.*MD5:\(\S*\) .*/\1/')
fi
openstack_keys=$(openstack keypair list -f value)

home_key_in_OS=$(echo "${openstack_keys}" | awk -v mykey="${home_key_fingerprint}" '$2 ~ mykey {print $1}')

if [[ -n "${home_key_in_OS}" ]]; then 
	#RESET this to key that's already in OS
  OS_KEYPAIR_NAME=${home_key_in_OS}
elif [[ -n $(echo "${openstack_keys}" | grep ${OS_KEYPAIR_NAME}) ]]; then
  openstack keypair delete ${OS_KEYPAIR_NAME}
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_KEYPAIR_NAME}
else
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_KEYPAIR_NAME}
fi

SERVER_UUID=$(curl http://169.254.169.254/openstack/latest/meta_data.json | jq '.uuid' | sed -e 's#"##g')

server_security_groups=$(openstack server show -f value -c security_groups ${SERVER_UUID} | sed -e "s#name=##" -e "s#'##g" | paste -s -)

if [[ ! ("${server_security_groups}" =~ "${OS_SSH_SECGROUP_NAMEOS_SSH_SECGROUP_NAME}") ]]; then
  echo -e "openstack server add security group ${SERVER_UUID} ${OS_SSH_SECGROUP_NAME}"
  openstack server add security group ${SERVER_UUID} ${OS_SSH_SECGROUP_NAME}
fi

if [[ ! ("${server_security_groups}" =~ "${OS_INTERNAL_SECGROUP_NAME}") ]]; then
  echo -e "openstack server add security group ${SERVER_UUID} ${OS_INTERNAL_SECGROUP_NAME}"
  openstack server add security group ${SERVER_UUID} ${OS_INTERNAL_SECGROUP_NAME}
fi

if [[ "${volume_size}" != "0" ]]; then
  echo "Creating volume ${volume_name} of ${volume_size} GB"
  openstack volume create --size ${volume_size} ${volume_name}
  openstack server add volume --device /dev/sdb ${SERVER_UUID} ${volume_name}
  sleep 5 # To fix a wait issue in volume creation
  sudo mkfs.xfs /dev/sdb && sudo mkdir -m 777 /export
  vol_uuid=$(sudo blkid /dev/sdb | sed "s|.*UUID=\"\(.\{36\}\)\" .*|\1|")
  echo "volume uuid is: ${vol_uuid}"
  echo -e \"UUID=${vol_uuid} /export                 xfs     defaults        0 0\" | sudo tee -a /etc/fstab && sudo mount -a
  echo "Volume sdb has UUID ${vol_uuid}"
  if [[ ${docker_allow} == 1 ]]; then
    echo -E '{ \"data-root\": \"/export/docker\" }' | sudo tee -a /etc/docker/daemon.json && sudo systemctl restart docker
  fi

fi

if [[ (! ("${server_security_groups}" =~ "${OS_HTTP_S_SECGROUP_NAME}")) && "${install_opts}" =~ "-j" ]]; then
  openstack server add security group ${SERVER_UUID} ${OS_HTTP_S_SECGROUP_NAME}
fi
  
echo "Beginning Slurm installation and Compute Image configuration - should take 8-10 minutes."

sudo mkdir -p /etc/slurm
sudo cp "${openrc_path}" /etc/slurm/openrc.sh
sudo chmod 400 /etc/slurm/openrc.sh

sudo ./install_local.sh ${install_opts}

if [[ ${install_opts} =~ "-j" ]]; then
  echo "You will need to edit the file ${PWD}/install_jupyterhub.yml to reflect the public hostname of your new cluster, and use your email for SSL certs."
  echo "Then, run the following command from the directory ${PWD} on this instance to complete your jupyterhub setup:"
  echo "sudo ansible-playbook -v --ssh-common-args='-o StrictHostKeyChecking=no' install_jupyterhub.yml"
fi
