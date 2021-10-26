#!/bin/bash

source ./openrc-staff.sh

compute_image="${OS_PROJECT_NAME}-vc-compute-image-latest"
compute_instance="compute-jec-test-base-instance"

openstack server stop ${compute_instance}

count=0
declare -i count
until [[ ${count} -ge 12 || "${shutoff_check}" =~ "SHUTOFF" ]];
do
  shutoff_check=$(openstack server show -f value -c status ${compute_instance})
  count+=1
  sleep 5
done

image_check=$(openstack image show -f value -c name ${compute_image})
# If there is already a -latest image, re-name it with the date of its creation
if [[ -n ${image_check} ]];
then
  old_image_date=$(openstack image show ${compute_image} -f value -c created_at | cut -d'T' -f 1)
  backup_image_name=${compute_image::-7}-${old_image_date}

  if [[ ${old_image_date} == "$(date +%Y-%m-%d)" && -n "$(openstack image show -f value -c name ${backup_image_name})" ]]; 
  then
    openstack image delete ${backup_image_name}
  fi

  openstack image set --name ${backup_image_name} ${compute_image}
fi

openstack server image create --name ${compute_image} ${compute_instance}

count=0
declare -i count
until [[ ${count} -ge 20 || "${instance_check}" =~ "active" ]];
do
  instance_check=$(openstack image show -f value -c status ${compute_image})
  count+=1
  sleep 15
done

if [[ ${count} -ge 20 ]];
then
  echo "Image still in queued status after 300 seconds"
  exit 2
fi

echo "Done after ${count} sleeps."

openstack image list | grep $(hostname -s)
openstack server delete ${compute_instance}
