#!/bin/bash

source /etc/slurm/openrc.sh

os_error_list=$(openstack server list --status ERROR -f value -c ID)
logfile=/var/log/slurm/os_clean.log

for host_id in $os_error_list
do
  echo "Removing OS_HOST $host_id" >> $logfile 2>&1
  openstack server show $host_id >> $logfile 2>&1
  openstack server delete $host_id >> $logfile 2>&1
done
