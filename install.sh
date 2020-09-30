#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

#do this early, allow the user to leave while the rest runs!
#These must match those defined in headnode_create.sh
source ./openrc.sh
OS_PREFIX=$(hostname -s)
OS_SLURM_KEYPAIR=${OS_PREFIX}-slurm-key
OS_APP_CRED=${OS_PREFIX}-slurm-app-cred
SUBNET_PREFIX=10.0.0

yum -y install https://github.com/openhpc/ohpc/releases/download/v1.3.GA/ohpc-release-1.3-1.el7.x86_64.rpm \
       centos-release-openstack-rocky

yum -y install \
        ohpc-slurm-server \
        vim \
        ansible \
        mailx \
        lmod-ohpc \
        bash-completion \
        gnu-compilers-ohpc \
        openmpi-gnu-ohpc \
        singularity-ohpc \
        lmod-defaults-gnu-openmpi-ohpc \
        moreutils \
        bind-utils \
        python2-openstackclient \
	python2-pexpect

yum -y update  # until the base python2-openstackclient install works out of the box!

#create user that can be used to submit jobs
[ ! -d /home/gateway-user ] && useradd -m gateway-user

[ ! -f slurm-key ] && ssh-keygen -b 2048 -t rsa -P "" -f slurm-key

# generate a local key for centos for after homedirs are mounted!
[ ! -f /home/centos/.ssh/id_rsa ] && su centos - -c 'ssh-keygen -t rsa -b 2048 -P "" -f /home/centos/.ssh/id_rsa && cat /home/centos/.ssh/id_rsa.pub >> /home/centos/.ssh/authorized_keys'


#create clouds.yaml file from contents of openrc
echo -e "clouds: 
  jetstream:
    auth:
      username: ${OS_USERNAME}
      auth_url: ${OS_AUTH_URL}
      project_name: ${OS_PROJECT_NAME}
      password: ${OS_PASSWORD}
    user_domain_name: ${OS_USER_DOMAIN_NAME}
    project_domain_name: ${OS_PROJECT_DOMAIN_NAME}
    identity_api_version: 3" > clouds.yaml

# There are different versions of openrc floating around between the js wiki and auto-generated openrc files.
if [[ -n ${OS_PROJECT_DOMAIN_NAME} ]]; then
  echo -e "    project_domain_name: ${OS_PROJECT_DOMAIN_NAME}" >> clouds.yaml
elif [[ -n ${OS_PROJECT_DOMAIN_ID} ]]; then
  echo -e "    project_domain_id: ${OS_PROJECT_DOMAIN_ID}" >> clouds.yaml
fi

if [[ -n $(openstack keypair list | grep ${OS_SLURM_KEYPAIR}) ]]; then
  openstack keypair delete ${OS_SLURM_KEYPAIR}
  openstack keypair create --public-key slurm-key.pub ${OS_SLURM_KEYPAIR}
else
  openstack keypair create --public-key slurm-key.pub ${OS_SLURM_KEYPAIR}
fi

#TACC-specific changes:

if [[ $OS_AUTH_URL =~ "tacc" ]]; then
  #Insert headnode into /etc/hosts
  echo "$(ip add show dev eth0 | awk '/inet / {sub("/24","",$2); print $2}') $(hostname) $(hostname -s)" >> /etc/hosts
fi

#Get OS Network name of *this* server, and set as the network for compute-nodes
# Only need this if you've changed the subnet name for some reason
#headnode_os_subnet=$(openstack server show $(hostname | cut -f 1 -d'.') | awk '/addresses/ {print $4}' | cut -f 1 -d'=')
#sed -i "s/network_name=.*/network_name=$headnode_os_subnet/" ./slurm_resume.sh

#Set compute node names to $OS_USERNAME-compute-
sed -i "s/=compute-*/=${OS_PREFIX}-compute-/" ./slurm.conf
sed -i "s/Host compute-*/Host ${OS_PREFIX}-compute-/" ./ssh.cfg

#set the subnet in ssh.cfg and compute_build_base_img.yml
sed -i "s/Host 10.0.0.\*/Host ${SUBNET_PREFIX}.\*/" ./ssh.cfg
sed -i "s/^\(.*\)10.0.0\(.*\)$/\1${SUBNET_PREFIX}\2/" ./compute_build_base_img.yml

# Deal with files required by slurm - better way to encapsulate this section?

mkdir -p -m 700 /etc/slurm/.ssh

cp slurm-key slurm-key.pub /etc/slurm/.ssh/

#Make sure slurm-user will still be valid after the nfs mount happens!
cat slurm-key.pub >> /home/centos/.ssh/authorized_keys

chown -R slurm:slurm /etc/slurm/.ssh

setfacl -m u:slurm:rw /etc/hosts
setfacl -m u:slurm:rwx /etc/

chmod +t /etc

#Possible to handle this at the cloud-init level? From a machine w/
# pre-loaded openrc, possible via user-data and write_files, yes.
echo -e "export OS_PROJECT_DOMAIN_NAME=${OS_PROJECT_DOMAIN_NAME}
export OS_USER_DOMAIN_NAME=${OS_USER_DOMAIN_NAME}
export OS_PROJECT_NAME=${OS_PROJECT_NAME}
export OS_USERNAME=${OS_USERNAME}
export OS_PASSWORD=${OS_PASSWORD}
export OS_AUTH_URL=${OS_AUTH_URL}
export OS_IDENTITY_API_VERSION=3" > /etc/slurm/openrc.sh


chown slurm:slurm /etc/slurm/openrc.sh

chmod 400 /etc/slurm/openrc.sh

cp prevent-updates.ci /etc/slurm/

chown slurm:slurm /etc/slurm/prevent-updates.ci

mkdir -p /var/log/slurm

touch /var/log/slurm/slurm_elastic.log
touch /var/log/slurm/os_clean.log

chown -R slurm:slurm /var/log/slurm

cp slurm-logrotate.conf /etc/logrotate.d/slurm

setfacl -m u:slurm:rw /etc/ansible/hosts
setfacl -m u:slurm:rwx /etc/ansible/

cp slurm_*.sh /usr/local/sbin/

cp cron-node-check.sh /usr/local/sbin/
cp clean-os-error.sh /usr/local/sbin/

chown slurm:slurm /usr/local/sbin/slurm_*.sh
chown slurm:slurm /usr/local/sbin/clean-os-error.sh

chown centos:centos /usr/local/sbin/cron-node-check.sh

echo "#13 */6  *  *  * centos     /usr/local/sbin/cron-node-check.sh" >> /etc/crontab
echo "#*/4 *  *  *  * slurm     /usr/local/sbin/clean-os-error.sh" >> /etc/crontab

#"dynamic" hostname adjustment
sed -i "s/ControlMachine=slurm-example/ControlMachine=$(hostname -s)/" ./slurm.conf
cp slurm.conf /etc/slurm/slurm.conf

cp ansible.cfg /etc/ansible/

cp ssh.cfg /etc/ansible/

cp slurm_test.job ${HOME}

#create share directory
mkdir -m 777 -p /export

#create export of homedirs and /export and /opt/ohpc/pub
echo -e "/home ${SUBNET_PREFIX}.0/24(rw,no_root_squash) \n/export ${SUBNET_PREFIX}.0/24(rw,no_root_squash)" > /etc/exports
echo -e "/opt/ohpc/pub ${SUBNET_PREFIX}.0/24(rw,no_root_squash)" >> /etc/exports

#Get latest CentOS7 minimal image for base - if os_image_facts or the os API allowed for wildcards,
#  this would be different. But this is the world we live in.
# After the naming convention change of May 5, 2020, this is no longer necessary - JS-API-Featured-CentOS7-Latest is the default.
# These lines remain as a testament to past struggles.
#centos_base_image=$(openstack image list --status active | grep -iE "API-Featured-centos7-[[:alpha:]]{3,4}-[0-9]{2}-[0-9]{4}" | awk '{print $4}' | tail -n 1)
#centos_base_image="JS-API-Featured-CentOS7-Latest"
#sed -i "s/\(\s*compute_base_image: \).*/\1\"${centos_base_image}\"/" compute_build_base_img.yml | head -n 10

#create temporary script to add local users
echo "#!/bin/bash" > /tmp/add_users.sh
cat /etc/passwd | awk -F':' '$4 >= 1001 && $4 < 65000 {print "useradd -M -u", $3, $1}' >> /tmp/add_users.sh

# build instance for compute base image generation, take snapshot, and destroy it
echo "Creating compute image! based on $centos_base_image"

ansible-playbook -v --ssh-common-args='-o StrictHostKeyChecking=no' compute_build_base_img.yml

#to allow other users to run ansible!
rm -r /tmp/.ansible

#Start required services
systemctl enable slurmctld munge nfs-server nfs-lock nfs rpcbind nfs-idmap
systemctl start munge slurmctld nfs-server nfs-lock nfs rpcbind nfs-idmap

echo -e "If you wish to enable an email when node state is drain or down, please uncomment \nthe cron-node-check.sh job in /etc/crontab, and place your email of choice in the 'email_addr' variable \nat the beginning of /usr/local/sbin/cron-node-check.sh"
