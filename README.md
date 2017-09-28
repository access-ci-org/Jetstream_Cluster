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

## Potential issues
* Cloud-init auto-runs yum update on the first boot, which takes approximately forever in computer-time (~10 minutes). 
* Might be best to create compute nodes initially, and then suspend/shelve them once that initialization happens - 'stop' might be the best way.

## Current Status

FIX INSTALL.SH TO GET THE SSH KEY NAME RIGHT!

As suspend_program and resume_program and compute_playbook currently 
stand, they will create a working compute node w/ running slurmd. 

Install script is working, except for the need to create an openrc.sh
file in the same directory. 

The create/suspend works ONCE the nodes have been initially created. 
If the node already exists, the openstack stop/start are used.
Haven't properly tested whether the resume will function still when the node
doesn't yet exist. Seemed like there may be timeout issues.

Testing note:
Slurm will run suspend/resume in response to 
scontrol update nodename=compute-[0-1] state=power_down/up

Might need to change compute node-name to include the OS_USERNAME,
so that we don't end up with server name clashing...

Something is up with the mount command; further ansible commands FAIL
after it is run.

## Necessary Bits


For Headnode install/setup:
* Need to set up ansible for compute node acccess
  * Need ansible.cfg to point to an ssh.cfg
  * Need the ssh.cfg to point to the same priv key as used in server create
  * Need to edit the host list on each create/suspend
  * Have to write headnode private IP into compute\_playbook
* SLURM USER WILL NEED AN SSH KEY!
* Need to setfacl on /etc/munge/munge.key to allow slurm to copy this over!!!
* Headnode needs to create a private network!!!
  * ResumeProgram also needs to know the name of it.
  * how will that work with the Atmosphere side?
  * ALSO, need to create/add an ssh key to openstack!
    * This ssh key needs to be usable by the slurm user
    * OR, allow host-based auth on the compute node
* create a log file in /var/log/slurm\_elastic.log
  * ```touch /var/log/slurm\_elastic.log && chown slurm:slurm /var/log/slurm\_elastic.log```
* Export of /home to 10.0.0.0/24 
* Firewall allow all to 10., allow only ssh from external.
  * public.xml sets this up properly
  * ALSO, had to yum install firewalld...
* just do a global install of ansible on the headnode.
* files compute nodes must receive:
  * /etc/slurm/slurm.conf
  * /etc/passwd
  * /etc/groups
  * /etc/hosts
* list of extra software to install: (extra meaning additional to Cent7 minimal?)
  * ansible
  * firewalld
  * pdsh (BEFORE slurm is started)
  * OpenMPI
  * MVAPICH2
  * openhpc-slurm
  * openhpc-slurm-server
  * chronyd?
  * polictycoreutils-python
  * tcpdump
  * bind-utils
  * strace
  * lsof
  * XNIT repo!

These bits need to happen in ResumeProgram

* ResumeProgram needs to create node and attach to the private network
  * this is done, w/ hardcoded network, etc. 
    * NEED TO MAKE THIS DYNAMIC! Modify in cloud-init of headnode build!
  * This is also going to run as the slurm user... permissions issues? solved!
* must result in started slurmd (does)
* update nodename via scontrol  (does)

SuspendProgram can just openstack server stop - destroy may also be an option, but the
 initial cloud-init build is very slow!

