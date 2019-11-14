#!/bin/bash

source /etc/slurm/openrc.sh

log_loc=/var/log/slurm/slurm_elastic.log
#log_loc=/dev/stdout 

echo "$(date) Node suspend invoked: $0 $*" >> $log_loc

##############################
# active_hosts takes in a hostlist, and echos an updated list of instances
# that are still active - this simplifies the count-loop below, which should
# loop only over active instances
##############################
active_hosts() {

hostlist="$1"
os_status_list=$(openstack server list -f value -c ID -c Name -c Status)

updated_hosts=""

for host in $hostlist
do
  # the quotes around os_status_list preserve newlines!
  if [[ "$(echo "$os_status_list" | awk -v host="$host " '$0 ~ host {print $3}')" == "ACTIVE" ]]; then
    echo -n "$host "
  elif [[ $(echo "${os_status_list}" | grep "$host " | wc -l) -ge 2 ]]; then
    #switch to using OS id, because we have multiples of the same host
    echo -n $(echo "${os_status_list}" | awk -v host="$host " '$0 ~ host {print $1}')
  fi
done


return 0

}
##############################

count=0
declare -i count

hostlist=$(scontrol show hostname $1 | tr '\n' ' ' | sed 's/[ ]*$//')

#Now, try 3 times to ensure all hosts are suspended...
until [ -z "${hostlist}" -o $count -ge 3 ]; 
do
  for host in $hostlist 
  do
    #remove from /etc/ansible/hosts and /etc/hosts
    if [[ $count == 0 ]]; then
      sed "/$host/d" /etc/hosts 2>&1 | sponge /etc/hosts >> $log_loc
      sed "/$host/d" /etc/ansible/hosts 2>&1 | sponge /etc/ansible/hosts >> $log_loc
      scontrol update nodename=${host} nodeaddr="(null)" >> $log_loc
    fi
    destroy_result=$(openstack server delete $host 2>&1) 
    echo "$(date) Deleted $host: $destroy_result" >> $log_loc
  done

  sleep 5 #wait a bit for hosts to enter STOP state
  count+=1
  hostlist="$(active_hosts "${hostlist}")"
  echo "$(date) delete Attempt $count: remaining hosts: $hostlist" >> $log_loc
done
