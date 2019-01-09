#!/bin/bash

source openrc.sh

compute_image="${OS_USERNAME}-compute-image-$(date +%m-%d-%Y)"
compute_instance="compute-${OS_USERNAME}-base-instance"

openstack server stop $compute_instance

count=0
declare -i count
until [[ $count -ge 12 || "$shutoff_check" =~ "SHUTOFF" ]];
do
  shutoff_check=$(openstack server show -f value -c status $compute_instance)
  count+=1
  sleep 5
done

openstack server image create --name $compute_image $compute_instance

count=0
declare -i count
until [[ $count -ge 20 || "$instance_check" =~ "active" ]];
do
  instance_check=$(openstack image show -f value -c status $compute_image)
  count+=1
  sleep 15
done

echo "Done after $count sleeps."
openstack image show $compute_image
