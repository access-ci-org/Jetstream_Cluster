#!/bin/bash

source /etc/slurm/openrc.sh

log_loc=/var/log/slurm/slurm_elastic.log
#log_loc=/dev/stdout 

echo "$(date) Node suspend invoked: $0 $*" >> $log_loc

##hostlist=$(openstack server list)
#
#
#for host in $(scontrol show hostname $1)
#do
#  sed -i "s/^$host.*//" /etc/ansible/hosts
#  if [[ "$(echo "$hostlist" | awk -v host=$host '$0 ~ host {print $6}')" == "ACTIVE" ]]; then 
#    stop_result=$(openstack server stop $host 2>&1) 
#    echo "$(date) Stopped $host: $stop_result" >> $log_loc
#  else
#    echo "$host not ACTIVE" >> $log_loc
#  fi
#done

hostlist=$(scontrol show hostname $1 | tr '\n' ' ' | sed 's/[ ]*$//')

##############################
# active_hosts takes in a hostlist, and echos an updated list of instances
# that are still active
##############################
active_hosts() {

hostlist="$1"
os_status_list=$(openstack server list)

updated_hosts=""

for host in $hostlist
do
  if [[ "$(echo "$os_status_list" | awk -v host=$host '$0 ~ host {print $6}')" == "ACTIVE" ]]; then 
    echo -n "$host "
  fi
done

return 0

}
##############################

#Now, try 3 times to ensure all hosts are suspended...
count=0
declare -i count

until [ -z "${hostlist}" -o $count -ge 3 ]; 
do
  for host in $hostlist 
  do
    #remove from /etc/ansible/hosts
    if [[ $count == 0 ]]; then
      sed -i "/$host/d" /etc/ansible/hosts
    fi
    stop_result=$(echo "openstack server stop $host" 2>&1) 
    echo "$(date) Stopped $host: $stop_result" >> $log_loc
  done

  sleep 5 #wait a bit for hosts to enter STOP state
  count+=1
  hostlist="$(active_hosts "${hostlist}")"
  echo "$(date) suspend Attempt $count: remaining hosts: $hostlist" >> $log_loc
done
