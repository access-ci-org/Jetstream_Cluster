#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

yum -y install https://github.com/openhpc/ohpc/releases/download/v1.3.GA/ohpc-release-1.3-1.el7.x86_64.rpm

yum -y install ohpc-slurm-server ansible mailx

pip install python-openstackclient

#already did this step locally...
ssh-keygen -b 2048 -t rsa -P "" -f slurm-key

# generate a local key for centos for after homedirs are mounted!
su centos - -c 'ssh-keygen -t rsa -b 2048 -P "" -f /home/centos/.ssh/id_rsa'

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

#quota_check "key-pairs" "keypair" 1
security_groups=$(openstack security group list -f value)
if [[ $(quota_check "secgroups" "security group" 2) ]]; then
  if [[ ! ("$security_groups" =~ "global-ssh") && ("$security_groups" =~ "cluster-internal") ]]; then
    echo "NOT ENOUGH SECURITY GROUPS REMAINING IN YOUR ALLOCATION! EITHER ASK FOR A QUOTA INCREASE, OR REMOVE SOME SECURITY GROUPS"
    exit
  fi
fi

#quota_check "instances" "server" 1

if [[ -n $(openstack keypair list | grep ${OS_USERNAME}-slurm-key) ]]; then
  openstack keypair delete ${OS_USERNAME}-slurm-key
  openstack keypair create --public-key slurm-key.pub ${OS_USERNAME}-slurm-key
else
  openstack keypair create --public-key slurm-key.pub ${OS_USERNAME}-slurm-key
fi

#make sure security groups exist... this could cause issues.
if [[ ! ("$security_groups" =~ "global-ssh") ]]; then
  openstack security group create --description "ssh \& icmp enabled" global-ssh
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 global-ssh
  openstack security group rule create --protocol icmp global-ssh
fi
if [[ ! ("$security_groups" =~ "cluster-internal") ]]; then
  openstack security group create --description "internal 10.0.0.0/24 network allowed" cluster-internal
  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip 10.0.0.0/24 cluster-internal
  openstack security group rule create --protocol udp --dst-port 1:65535 --remote-ip 10.0.0.0/24 cluster-internal
  openstack security group rule create --protocol icmp cluster-internal
fi

#Get OS Network name of *this* server, and set as the network for compute-nodes
headnode_os_subnet=$(openstack server show $(hostname | cut -f 1 -d'.') | awk '/addresses/ {print $4}' | cut -f 1 -d'=')
sed -i "s/network_name=.*/network_name=$headnode_os_subnet/" ./slurm_resume.sh

# Deal with files required by slurm - better way to encapsulate this section?

mkdir -p -m 700 /etc/slurm/.ssh

cp slurm-key slurm-key.pub /etc/slurm/.ssh/

#Make sure slurm-user will still be valid after the nfs mount happens!
cat slurm-key.pub >> /home/centos/.ssh/authorized_keys

chown -R slurm:slurm /etc/slurm/.ssh

cp /etc/munge/munge.key /etc/slurm/.munge.key

chown slurm:slurm /etc/slurm/.munge.key

#How to generate a working openrc in the cloud-init script for this? Bash vars available?
# Gonna be tough, since openrc requires a password...
cp openrc.sh /etc/slurm/

chown slurm:slurm /etc/slurm/openrc.sh

chmod 400 /etc/slurm/openrc.sh

cp compute_playbook.yml /etc/slurm/

touch /var/log/slurm_elastic.log

chown slurm:slurm /var/log/slurm_elastic.log

setfacl -m u:slurm:rw /etc/ansible/hosts
setfacl -m u:slurm:rwx /etc/ansible/

cp slurm_*.sh /usr/local/sbin/

chown slurm:slurm /usr/local/sbin/slurm_*.sh

#"dynamic" hostname adjustment
sed -i "s/ControlMachine=slurm-example/ControlMachine=$(hostname -s)/" ./slurm.conf
cp slurm.conf /etc/slurm/slurm.conf

cp ansible.cfg /etc/ansible/

cp ssh.cfg /etc/ansible/

#create share directory
mkdir -m 777 -p /export

#create export of homedirs and /export
echo -e "/home 10.0.0.0/24(rw,no_root_squash) \n/export 10.0.0.0/24(rw,no_root_squash)" > /etc/exports

#Start required services
systemctl enable slurmctld munge nfs-server nfs-lock nfs rpcbind nfs-idmap
systemctl start munge slurmctld nfs-server nfs-lock nfs rpcbind nfs-idmap
