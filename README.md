# Elastic Slurm Cluster in a Jetstream image

## Intro

This is a simple repo to keep track of files, scripts, etc. that will
be useful for building an image in Jetstream that will act as an 
elastic SLURM cluster. This README will (until it becomes unwieldy)
contain notes, plans, etc. Feel free to stick necessary files in the
top level dir. 

The basic structure is to have a single image act as headnode, with
compute nodes managed by SLURM via the openstack API (via curl or
Ansible or whatever.). The current plan for compute nodes is to
use a basic Cent7 image, followed by some Ansible magic to add software,
mounts, users, slurm config files, etc.

## Necessary Bits

In no particular order:

* chrony should allow timestep jumps at any time!
* the compute node image should allow for this as well
* files compute nodes must receive:
..* /etc/slurm/slurm.conf
..* /etc/passwd
..* /etc/groups
..* /etc/hosts
* the headnode will need scripts for
..* starting a new CLOUD node
..* destroying a CLOUD node
* list of extra software to install: (extra meaning additional to Cent7 minimal?)
..* OpenMPI
..* MVAPICH2
..* openhpc-slurm
..* openhpc-slurm-server
..* chronyd?
..* polictycoreutils-python
..* tcpdump
..* bind-utils
..* strace
..* lsof
..* XNIT repo!
