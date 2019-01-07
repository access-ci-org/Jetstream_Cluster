#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

yum -y install https://github.com/openhpc/ohpc/releases/download/v1.3.GA/ohpc-release-1.3-1.el7.x86_64.rpm

yum -y install ohpc-slurm-server vim ansible mailx lmod-ohpc bash-completion gnu-compilers-ohpc openmpi-gnu-ohpc lmod-defaults-gnu-openmpi-ohpc


pip install python-openstackclient

#already did this step locally...
ssh-keygen -b 2048 -t rsa -P "" -f slurm-key

# generate a local key for centos for after homedirs are mounted!
su centos - -c 'ssh-keygen -t rsa -b 2048 -P "" -f /home/centos/.ssh/id_rsa'
su centos - -c 'cat /home/centos/.ssh/id_rsa.pub >> /home/centos/.ssh/authorized_keys'

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

if [[ -n $(openstack keypair list | grep ${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key) ]]; then
  openstack keypair delete ${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key
  openstack keypair create --public-key slurm-key.pub ${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key
else
  openstack keypair create --public-key slurm-key.pub ${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key
fi

#make sure security groups exist... this could cause issues.
if [[ ! ("$security_groups" =~ "global-ssh") ]]; then
  openstack security group create --description "ssh \& icmp enabled" ${OS_USERNAME}-global-ssh
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 ${OS_USERNAME}-global-ssh
  openstack security group rule create --protocol icmp ${OS_USERNAME}-global-ssh
fi
if [[ ! ("$security_groups" =~ "cluster-internal") ]]; then
  openstack security group create --description "internal 10.0.0.0/24 network allowed" ${OS_USERNAME}-cluster-internal
  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip 10.0.0.0/24 ${OS_USERNAME}-cluster-internal
  openstack security group rule create --protocol udp --dst-port 1:65535 --remote-ip 10.0.0.0/24 ${OS_USERNAME}-cluster-internal
  openstack security group rule create --protocol icmp ${OS_USERNAME}-cluster-internal
fi

#TACC-specific changes:

if [[ $OS_AUTH_URL =~ "tacc" ]]; then
  #Insert headnode into /etc/hosts
  echo "$(ip add show dev eth0 | awk '/inet / {sub("/24","",$2); print $2}') $(hostname) $(hostname -s)" >> /etc/hosts
fi

#Get OS Network name of *this* server, and set as the network for compute-nodes
headnode_os_subnet=$(openstack server show $(hostname | cut -f 1 -d'.') | awk '/addresses/ {print $4}' | cut -f 1 -d'=')
sed -i "s/network_name=.*/network_name=$headnode_os_subnet/" ./slurm_resume.sh

#Set compute node names to $OS_USERNAME-compute-
sed -i "s/compute-*/${OS_USERNAME}-compute-/" ./slurm.conf
sed -i "s/compute-*/${OS_USERNAME}-compute-/" ./ssh.cfg
sed -i "s/compute-*/${OS_USERNAME}-compute-/" ./compute_playbook.yml

# Deal with files required by slurm - better way to encapsulate this section?

mkdir -p -m 700 /etc/slurm/.ssh

cp slurm-key slurm-key.pub /etc/slurm/.ssh/

#Make sure slurm-user will still be valid after the nfs mount happens!
cat slurm-key.pub >> /home/centos/.ssh/authorized_keys

chown -R slurm:slurm /etc/slurm/.ssh

cp /etc/munge/munge.key /etc/slurm/.munge.key

chown slurm:slurm /etc/slurm/.munge.key

setfacl -m u:slurm:rw /etc/hosts

#How to generate a working openrc in the cloud-init script for this? Bash vars available?
# Gonna be tough, since openrc requires a password...
cp openrc.sh /etc/slurm/

chown slurm:slurm /etc/slurm/openrc.sh

chmod 400 /etc/slurm/openrc.sh

cp prevent-updates.ci /etc/slurm/

chown slurm:slurm /etc/slurm/prevent-updates.ci

mkdir /var/log/slurm

touch /var/log/slurm/slurm_elastic.log

chown -R slurm:slurm /var/log/slurm

cp slurm-logrotate.conf /etc/logrotate.d/slurm

setfacl -m u:slurm:rw /etc/ansible/hosts
setfacl -m u:slurm:rwx /etc/ansible/

cp slurm_*.sh /usr/local/sbin/

cp cron-node-check.sh /usr/local/sbin/

chown slurm:slurm /usr/local/sbin/slurm_*.sh

chown centos:centos /usr/local/sbin/cron-node-check.sh

echo "#13 */6  *  *  * centos     /usr/local/sbin/cron-node-check.sh" >> /etc/crontab

#"dynamic" hostname adjustment
sed -i "s/ControlMachine=slurm-example/ControlMachine=$(hostname -s)/" ./slurm.conf
cp slurm.conf /etc/slurm/slurm.conf

cp ansible.cfg /etc/ansible/

cp ssh.cfg /etc/ansible/

cp slurm_test.job ${HOME}

#create share directory
mkdir -m 777 -p /export

#create export of homedirs and /export and /opt/ohpc/pub
echo -e "/home 10.0.0.0/24(rw,no_root_squash) \n/export 10.0.0.0/24(rw,no_root_squash)" > /etc/exports
echo -e "/opt/ohpc/pub 10.0.0.0/24(rw,no_root_squash)" >> /etc/exports

# build instance for compute base image generation, take snapshot, and destroy it
echo "Creating comput image!"

ansible-playbook -vvv compute_build_base_img.yml

#Start required services
systemctl enable slurmctld munge nfs-server nfs-lock nfs rpcbind nfs-idmap
systemctl start munge slurmctld nfs-server nfs-lock nfs rpcbind nfs-idmap

echo -e "If you wish to enable an email when node state is drain or down, please uncomment \nthe cron-node-check.sh job in /etc/crontab, and place your email of choice in the 'email_addr' variable \nat the beginning of /usr/local/sbin/cron-node-check.sh"
