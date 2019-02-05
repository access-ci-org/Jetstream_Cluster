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

image_check=$(openstack image show -f value -c name $compute_image)
if [[ -n $image_check ]];
then
  openstack image delete $compute_image
fi

openstack server image create --name $compute_image $compute_instance

count=0
declare -i count
until [[ $count -ge 20 || "$instance_check" =~ "active" ]];
do
  instance_check=$(openstack image show -f value -c status $compute_image)
  count+=1
  sleep 15
done

if [[ $count -ge 20 ]];
then
  echo "Image still in queued status after 300 seconds"
  exit 2
fi

echo "Done after $count sleeps."
openstack image show $compute_image
