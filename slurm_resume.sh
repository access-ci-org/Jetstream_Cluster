#!/bin/bash

source /etc/slurm/openrc.sh

node_size="m1.small"
node_image=$(openstack image list -f value | grep JS-API-Featured-Centos7- | grep -vi Intel | cut -f 2 -d' ')
key_name="${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key"
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

#First, loop over hosts and run the openstack create/resume commands for *all* resume hosts at once.
#Avoids getting stuck if one host fails?
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
    --user-data /etc/slurm/prevent-updates.ci \
    --security-group global-ssh --security-group cluster-internal \
    --nic net-id=$network_name 2>&1 \
    | tee -a $log_loc | awk '/status/ {print $4}')
    
    echo "$host status is: $node_status" >> $log_loc
    
  else
    $node_status=$(openstack server start $host)
    echo "$host status is: $node_status" >> $log_loc
#    new_ip=$(openstack server show $host | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}')
  fi
done

#Now, check that hosts are up
for host in $(scontrol show hostname $1)
do
  until [[ $node_status == "ACTIVE" ]]; do
    sleep 3
    node_status=$(openstack server show $host | awk '/status/ {print $4}')
    echo "$host status is: $node_status" >> $log_loc
  done
   
  new_ip=$(openstack server show $host | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}')
  echo "Node ip is $new_ip" >> $log_loc
  sleep 10 # to give sshd time to be available
  test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg centos@$host 'hostname' | tee -a $log_loc)
  #  echo "test1: $test_hostname"
  until [[ $test_hostname =~ "compute" ]]; do
    sleep 2
    test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg centos@$host 'hostname' | tee -a $log_loc)
  done

  #add users Just in Case
  user_add_result=$(ansible -m script -a "/tmp/add_users.sh" $host)
  #echo "Tried to add users: " $user_add_result >> $log_loc
  # Commenting out - as run, this doesn't ignore the errors from extant users...

#Now, safe to update slurm w/ node info
#  echo "scontrol update nodename=$host nodeaddr=$new_ip" >> $log_loc
  scontrol update nodename=$host nodeaddr=$new_ip >> $log_loc

done

#Now, run ansible across everything? Don't trust the suspend hosts to work right! Why did I change this?
# Does mount /home make ansible fail? Sigh. Test this before changing!
echo "Running ansible on ${ansible_list::-1}" >> $log_loc
ansible-playbook -l "${ansible_list::-1}" /etc/slurm/compute_playbook.yml >> $log_loc
