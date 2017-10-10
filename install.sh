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

if [[ -n $(openstack keypair list | grep ${OS_USERNAME}-slurm-key) ]]; then
  openstack keypair delete ${OS_USERNAME}-slurm-key
  openstack keypair create --public-key slurm-key.pub ${OS_USERNAME}-slurm-key
else
  openstack keypair create --public-key slurm-key.pub ${OS_USERNAME}-slurm-key
fi

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

# This should include some dynamic modification of the file, to reflect 
#  the change in headnode hostname
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
