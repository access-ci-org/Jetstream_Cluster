#!/bin/bash

OPTIND=1

docker_allow=0 #default to NOT installing docker; must be 0 or 1
jhub_build=0 #default to NOT installing jupyterhub; must be 0 or 1

while getopts ":jd" opt; do
  case ${opt} in
    d) docker_allow=1
      ;;
    j) jhub_build=1
      ;;
    \?) echo "BAD OPTION! $opt TRY AGAIN"
      exit 1
      ;;
  esac
done

if [[ ! -e /etc/slurm/openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

#do this early, allow the user to leave while the rest runs!
source /etc/slurm/openrc.sh

OS_PREFIX=$(hostname -s)
OS_SLURM_KEYPAIR=${OS_PREFIX}-slurm-key

SUBNET_PREFIX=10.0.0

#Open the firewall on the internal network for Cent8
firewall-cmd --permanent --add-rich-rule="rule source address="${SUBNET_PREFIX}.0/24" family='ipv4' accept"
firewall-cmd --add-rich-rule="rule source address="${SUBNET_PREFIX}.0/24" family='ipv4' accept"

dnf -y install http://repos.openhpc.community/OpenHPC/2/CentOS_8/x86_64/ohpc-release-2-1.el8.x86_64.rpm \
       centos-release-openstack-train

dnf config-manager --set-enabled powertools

if [[ ${docker_allow} == 0 ]]; then
  dnf config-manager --set-disabled docker-ce-stable
  
  dnf -y remove containerd.io.x86_64 docker-ce.x86_64 docker-ce-cli.x86_64 docker-ce-rootless-extras.x86_64
fi

dnf -y --allowerasing install \
        ohpc-slurm-server \
        vim \
        ansible \
        mailx \
        lmod-ohpc \
        bash-completion \
        gnu9-compilers-ohpc \
        openmpi4-gnu9-ohpc \
        singularity-ohpc \
        lmod-defaults-gnu9-openmpi4-ohpc \
        moreutils \
        bind-utils \
        python3-openstackclient \
 	python3-pexpect

dnf -y update  # until the base python2-openstackclient install works out of the box!

#create user that can be used to submit jobs
[ ! -d /home/gateway-user ] && useradd -m gateway-user

[ ! -f slurm-key ] && ssh-keygen -b 2048 -t rsa -P "" -f slurm-key

# generate a local key for centos for after homedirs are mounted!
[ ! -f /home/centos/.ssh/id_rsa ] && su centos - -c 'ssh-keygen -t rsa -b 2048 -P "" -f /home/centos/.ssh/id_rsa && cat /home/centos/.ssh/id_rsa.pub >> /home/centos/.ssh/authorized_keys'


#create clouds.yaml file from contents of openrc
echo -e "clouds:
  tacc:
    auth:
      auth_url: '${OS_AUTH_URL}'
      application_credential_id: '${OS_APPLICATION_CREDENTIAL_ID}'
      application_credential_secret: '${OS_APPLICATION_CREDENTIAL_SECRET}'
    user_domain_name: tacc
    identity_api_version: 3
    project_domain_name: tacc
    auth_type: 'v3applicationcredential'" > clouds.yaml

#Make sure only root can read this
chmod 400 clouds.yaml

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

#Set compute node names to $OS_PREFIX-compute-
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

#The following may be removed when appcred gen during cluster_create is working
##Possible to handle this at the cloud-init level? From a machine w/
## pre-loaded openrc, possible via user-data and write_files, yes.
## This needs a check for success, and if not, fail?
##export $(openstack application credential create -f shell ${OS_APP_CRED} | sed 's/^\(.*\)/OS_ac_\1/')
##echo -e "export OS_AUTH_TYPE=v3applicationcredential
##export OS_AUTH_URL=${OS_AUTH_URL}
##export OS_IDENTITY_API_VERSION=3
##export OS_REGION_NAME="RegionOne"
##export OS_INTERFACE=public
##export OS_APPLICATION_CREDENTIAL_ID=${OS_ac_id}
##export OS_APPLICATION_CREDENTIAL_SECRET=${OS_ac_secret} > /etc/slurm/openrc.sh
#
#echo -e "export OS_PROJECT_DOMAIN_NAME=tacc
#export OS_USER_DOMAIN_NAME=tacc
#export OS_PROJECT_NAME=${OS_PROJECT_NAME}
#export OS_USERNAME=${OS_USERNAME}
#export OS_PASSWORD=${OS_PASSWORD}
#export OS_AUTH_URL=${OS_AUTH_URL}
#export OS_IDENTITY_API_VERSION=3" > /etc/slurm/openrc.sh

#chown slurm:slurm /etc/slurm/openrc.sh

#chmod 400 /etc/slurm/openrc.sh

cp prevent-updates.ci /etc/slurm/

chown slurm:slurm /etc/slurm/openrc.sh
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

if [[ ${jhub_build} == 1 ]]; then
  ansible-galaxy collection install community.general
  ansible-galaxy collection install ansible.posix
  ansible-galaxy install geerlingguy.certbot
#  ansible-playbook -v --ssh-common-args='-o StrictHostKeyChecking=no' install_jupyterhub.yml
fi

#Start required services
systemctl enable slurmctld munge nfs-server rpcbind 
systemctl restart munge slurmctld nfs-server rpcbind 

echo -e "If you wish to enable an email when node state is drain or down, please uncomment \nthe cron-node-check.sh job in /etc/crontab, and place your email of choice in the 'email_addr' variable \nat the beginning of /usr/local/sbin/cron-node-check.sh"
