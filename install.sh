#!/bin/bash

#NAIVE install script. Assumes slurmctld, etc. already installed.

cp slurm_*.sh /usr/local/sbin/

chown slurm:slurm /usr/local/sbin/slurm_*.sh
