#!/bin/bash

mount_test=$(grep home /etc/mtab)
count=0
declare -i count

until [ -n "${mount_test}" -o $count -ge 10 ]; 
do
  sleep 1
  count+=1
  mount_test=$(grep home /etc/mtab)
  echo "$count test: $mount_test"
done

if [[ $count -ge 10 ]]; then
 echo "FAILED TO MOUNT home - $hostname"
 exit 1
fi

echo "HOME IS MOUNTED! $hostname"

exit 0
