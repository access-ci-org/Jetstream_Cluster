#!/bin/bash

yum -y install https://github.com/openhpc/ohpc/releases/download/v1.3.GA/ohpc-release-1.3-1.el7.x86_64.rpm

yum -y install ohpc-slurm-server ansible

pip install python-openstackclient

#already did this step locally...
ssh-keygen -b 2048 -t rsa -P "" -f slurm-key

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

chown -R slurm:slurm /etc/slurm/.ssh

cp /etc/munge/munge.key /etc/slurm/.munge.key

chown slurm:slurm /etc/slurm/.munge.key

cp openrc.sh /etc/slurm/

chown slurm:slurm /etc/slurm/openrc.sh

chmod 400 /etc/slurm/openrc.sh

cp compute_playbook.yml /etc/slurm/

touch /var/log/slurm_elastic.log

chown slurm:slurm /var/log/slurm_elastic.log

setfacl -m u:slurm:rw /etc/ansible/hosts
setfacl -m u:slurm:rwx /etc/ansible/

#How to generate a working openrc in the cloud-init script for this? Bash vars available?
# Gonna be tough, since openrc requires a password...

cp slurm_*.sh /usr/local/sbin/

chown slurm:slurm /usr/local/sbin/slurm_*.sh

# This should include some dynamic modification of the file, to reflect 
#  the change in headnode hostname
cp slurm.conf /etc/slurm/slurm.conf

cp ansible.cfg /etc/ansible

#Start required services

systemctl enable slurmctld munge
systemctl start munge slurmctld
