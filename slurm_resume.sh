#!/bin/bash

source ./openrc.sh

node_size="m1.small"
node_image="JS-API-Featured-Centos7-Feb-7-2017"
key_name="slurm-test-key"
network_name=jecoulte-api-net
log_loc=/var/log/slurm_elastic.log

echo "Node create invoked: $0 $*" >> $log_loc

#echo -e "\nwrite-files:" > file_init.ci
#for file in /etc/slurm/slurm.conf /etc/munge/munge.key
#do
#  echo "$file"
#  echo -e "  - encoding: b64\n    content: $(base64 -w 0 $file)\n    owner: root:root\n    path: $file \n    permissions: '$(stat -c "%a" $file)'" >> file_init.ci
#done
#
#cat compute_init.ci file_init.ci > all_init.ci

for host in $(scontrol show hostname $1)
do
  
  echo "$host" >> /etc/ansible/hosts

#  --user-data all_init.ci \
  node_status=$(openstack server create $host \
  --flavor $node_size \
  --image $node_image \
  --key-name $key_name \
  --security-group global-ssh --security-group cluster-internal \
  --nic net-id=$network_name \
  | tee -a $log_loc | awk '/status/ {print $4}')
  
  echo "Node status is: $node_status" >> $log_loc
  
  until [[ $node_status == "ACTIVE" ]]; do
    sleep 3
    node_status=$(openstack server show $host | awk '/status/ {print $4}')
    echo "Node status is: $node_status" >> $log_loc
  done
   
  new_ip=$(openstack server show $host | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}')
  echo "Node ip is $new_ip" >> $log_loc
  echo "scontrol update nodename=$host nodeaddr=$new_ip" >> $log_loc
  sleep 10 # to give sshd time to be available
  test_hostname=$(ssh -i /home/jecoulte/.ssh/id_rsa centos@$host 'hostname')
  echo "test1: $test_hostname"
  until [[ $test_hostname =~ "compute" ]]; do
    sleep 2
    test_hostname=$(ssh -i /home/jecoulte/.ssh/id_rsa centos@$host 'hostname')
  done
  echo "test2: $test_hostname"
  ansible-playbook -v -l $host compute_playbook.yml >> $log_loc
  scontrol update nodename=$host nodeaddr=$new_ip >> $log_loc
done

#pdsh 'yum install slurmd munge'
#pdsh 'sudo systemctl restart ntpd' $1
#pdsh 'sudo systemctl restart slurmd' $1
