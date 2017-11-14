#!/bin/bash

source /etc/slurm/openrc.sh

node_size="m1.xlarge"
node_image=$(openstack image list -f value | grep JS-API-Featured-Centos7- | cut -f 2 -d' ')
key_name="${OS_USERNAME}-slurm-key"
network_name=tg829096-elastic-net
log_loc=/var/log/slurm_elastic.log

echo "Node resume invoked: $0 $*" >> $log_loc

#echo -e "\nwrite-files:" > file_init.ci
#for file in /etc/slurm/slurm.conf /etc/munge/munge.key
#do
#  echo "$file"
#  echo -e "  - encoding: b64\n    content: $(base64 -w 0 $file)\n    owner: root:root\n    path: $file \n    permissions: '$(stat -c "%a" $file)'" >> file_init.ci
#done
#
#cat compute_init.ci file_init.ci > all_init.ci

#eh. useradd won't do anything if the user exists. just have to make sure ansible doesn't flip
# out when it 'fails' on suspend.
echo "#!/bin/bash" > /tmp/add_users.sh
cat /etc/passwd | awk -F':' '$4 >= 1001 && $4 < 65000 {print "useradd -M -u", $4, $1}' >> /tmp/add_users.sh

ansible_list=""
for host in $(scontrol show hostname $1)
do
  echo "$host ansible_user=centos ansible_become=true" >> /etc/ansible/hosts

  if [[ "$(openstack server show $host 2>&1)" =~ "No server with a name or ID of" ]]; then 

    ansible_list+="$host,"

    node_status=$(openstack server create $host \
    --flavor $node_size \
    --image $node_image \
    --key-name $key_name \
    --user-data prevent-updates.ci \
    --security-group global-ssh --security-group cluster-internal \
    --nic net-id=$network_name 2>&1 \
    | tee -a $log_loc | awk '/status/ {print $4}')
    
    echo "Node status is: $node_status" >> $log_loc
    
    until [[ $node_status == "ACTIVE" ]]; do
      sleep 3
      node_status=$(openstack server show $host | awk '/status/ {print $4}')
      echo "Node status is: $node_status" >> $log_loc
    done
     
    new_ip=$(openstack server show $host | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}')
    echo "Node ip is $new_ip" >> $log_loc
#    echo "scontrol update nodename=$host nodeaddr=$new_ip" >> $log_loc
    sleep 10 # to give sshd time to be available
    test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg centos@$host 'hostname' | tee -a $log_loc)
  #  echo "test1: $test_hostname"
    until [[ $test_hostname =~ "compute" ]]; do
      sleep 2
      test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg centos@$host 'hostname' | tee -a $log_loc)
    done
  #  echo "test2: $test_hostname"
  # What's the right place for this to live?
  else
    openstack server start $host
    new_ip=$(openstack server show $host | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}')
  fi
  scontrol update nodename=$host nodeaddr=$new_ip >> $log_loc
done

echo "Running ansible on ${ansible_list::-1}" >> $log_loc
ansible-playbook -l "${ansible_list::-1}" /etc/slurm/compute_playbook.yml >> $log_loc
