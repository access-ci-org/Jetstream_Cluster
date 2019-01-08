#!/bin/bash

source /etc/slurm/openrc.sh

node_size="m1.small"
node_image=$(openstack image list -f value | grep -i ${OS_USERNAME}-compute-image- | cut -f 2 -d' '| head -n 1)
key_name="${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key"
network_name=${OS_USERNAME}-elastic-net
log_loc=/var/log/slurm/slurm_elastic.log

echo "Node resume invoked: $0 $*" >> $log_loc

#useradd won't do anything if the user exists. 
echo "#!/bin/bash" > /tmp/add_users.sh
cat /etc/passwd | awk -F':' '$4 >= 1001 && $4 < 65000 {print "useradd -M -u", $3, $1}' >> /tmp/add_users.sh

#First, loop over hosts and run the openstack create commands for *all* resume hosts at once.
ansible_list=""
for host in $(scontrol show hostname $1)
do
  echo "$host ansible_user=centos ansible_become=true" >> /etc/ansible/hosts

  echo "openstack server create $host --flavor $node_size --image $node_image --key-name $key_name --user-data <(cat /etc/slurm/prevent-updates.ci && echo -e "hostname: $host \npreserve_hostname: true\ndebug:") --security-group global-ssh --security-group cluster-internal --nic net-id=$network_name" >> $log_loc

# For use when you've hit your security group quota...
#    --security-group global-ssh --security-group cluster-internal \
    node_status=$(openstack server create $host \
    --flavor $node_size \
    --image $node_image \
    --key-name $key_name \
    --user-data <(cat /etc/slurm/prevent-updates.ci && echo -e "hostname: $host \npreserve_hostname: true\ndebug:") \
    --security-group ${OS_USERNAME}-global-ssh --security-group ${OS_USERNAME}-cluster-internal \
    --nic net-id=$network_name 2>&1 \
    | tee -a $log_loc | awk '/status/ {print $4}')
    
    echo "$host status is: $node_status" >> $log_loc
done

#Now, check that hosts are up
for host in $(scontrol show hostname $1)
do
  until [[ $node_status == "ACTIVE" ]]; do
    sleep 3
    node_status=$(openstack server show $host 2>&1 | awk '/status/ {print $4}')
    echo "$host status is: $node_status" >> $log_loc
  done
   
  new_ip=$(openstack server show $host | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}')
  echo "$host ip is $new_ip" >> $log_loc 

  # now that we have the ip, make sure it's in etc/hosts, as we can't always trust to dns
  ip_check=$(grep $new_ip /etc/hosts)
#  echo "Found $ip_check in /etc/hosts new_ip check" >> $log_loc
  host_check=$(grep $host /etc/hosts)
#  echo "Found $host_check in /etc/hosts host_check" >> $log_loc
  if [[ -n $ip_check && ! ( $ip_check =~ $host ) ]]; then
   # this is bad, as slurm_suspend should remove the /etc/hosts entry for old nodes
   # ACTUALLY, this causes an issue with a compute node that receives the same IP and hasn't been removed from /etc/hosts...
   echo "OVERLAPPING ENTRY FOR $new_ip of $host in /etc/hosts: $ip_check" >> $log_loc
   exit 2
  fi
  if [[ -n $host_check && ! ( $host_check =~ $new_ip ) ]]; then
    echo "REPLACING $host_check with $new_ip for $host" >> $log_loc
    sed "s/.*$host/$new_ip $host/" /etc/hosts 2>&1 | sponge /etc/hosts >> $log_loc # due to the sticky bit required on /etc by munge
#    echo "$? result of sed" >> $log_loc
  fi
  if [[ -z $host_check ]]; then 
    echo "ADDING NEW ENTRY for $host at $new_ip IN /etc/hosts" >> $log_loc
    echo "$new_ip $host" >> /etc/hosts
  fi

  sleep 10 # to give sshd time to be available

  test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg $host 'hostname' | tee -a $log_loc)
  #  echo "test1: $test_hostname"
  until [[ -n "${test_hostname}" ]]; do
    sleep 5
    test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg $host 'hostname' | tee -a $log_loc)
#    echo "TESTING SSH ACCESS: $test_hostname" >> $log_loc
  done

  #reset the hostname JIC - no need for this w/ correctly built image
  #hostname_set_result=$(ansible -m hostname -a "name=$host" $host)
  #add users in case any added since image build
  user_add_result=$(ansible -m script -a "/tmp/add_users.sh" $host)
#  echo "Tried to add users: " $user_add_result >> $log_loc
  hosts_add_result=$(ansible -m copy -a "src=/etc/hosts dest=/etc/hosts" $host)
#  echo "Tried to add hosts $hosts_add_result" >> $log_loc
  slurm_sync_result=$(ansible -m copy -a "src=/etc/slurm/slurm.conf dest=/etc/slurm/slurm.conf" $host)
#  echo "Tried to sync slurm.conf $slurm_sync_result" >> $log_loc
  slurmd_start_result=$(ansible -m service -a "name=slurmd state=started enabled=yes" $host)
#  echo "Tried to start slurmd $slurm_start_result" >> $log_loc

#Now, safe to update slurm w/ node info
  scontrol update nodename=$host nodeaddr=$new_ip >> $log_loc

done

#if [[ -n $ansible_list ]]; then
#  echo "Running ansible on ${ansible_list::-1}" >> $log_loc
#  ansible-playbook -l "${ansible_list::-1}" /etc/slurm/compute_playbook.yml >> $log_loc
#fi
