#!/bin/bash

#This should run as the centos user - not root! Needs both sudo and job-running capabilities.
last_job_date=$(sudo grep job_complete /var/log/slurmctld.log | tail -n 1 | sed 's/\[\(.*\)T.*/\1/')

#This will run every day, so... no need to check any other condition?
if [[ $last_job_date == $(date --date="-1 week" "+%Y-%m-%d") ]]; then
  echo "submit a job"
  for partition in $(sinfo -h | tr -d '*' | tr ' ' '_'); do
    job_file=$(mktemp -p /tmp prevent_shelve.XXXX)
    echo $partition | awk -F'_*' '{print "#SBATCH -p", $1, "\n#SBATCH -N", $4, "\nsrun -l hostname"}' > $job_file
    sbatch $job_file
  done
fi
