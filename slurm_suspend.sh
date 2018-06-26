#!/bin/bash

source /etc/slurm/openrc.sh

log_loc=/var/log/slurm_elastic.log
#log_loc=/dev/stdout 

echo "Node suspend invoked: $0 $*" >> $log_loc

hostlist=$(openstack server list)

for host in $(scontrol show hostname $1)
do
  sed -i "/$host/d" /etc/ansible/hosts
  #sed -i "/$host/d" /etc/hosts #UNCOMMENT IF ON TACC!
  if [[ "$(echo "$hostlist" | awk -v host=$host '$0 ~ host {print $6}')" == "ACTIVE" ]]; then 
    echo "Stopping $host" >> $log_loc
    openstack server stop $host
  else
    echo "$host not ACTIVE" >> $log_loc
  fi
done
