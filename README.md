# Elastic Slurm Cluster on the Jetstream 2 Cloud

## Intro

This repo contains scripts and ansible playbooks for creating a virtual 
cluster in an Openstack environment, specifically aimed at the XSEDE 
Jetstream2 resource.

The basic structure is to have a single image act as headnode, with
compute nodes managed by SLURM via the openstack API. A customized 
image is created for worker nodes, which contains configuration 
and software specific to that cluster. The Slurm daemon on the
headnode dynamically creates and destroys worker nodes in response to 
jobs in the queue (refer to the figure below). The current version is based on Rocky Linux 8, using
RPMs from the [OpenHPC project](https://openhpc.community).

As current installation scripts work for Rocky Linux 8 distribution it is expected to have
a virtual machine created from the latest Rocky Linux 8 base image in Jestream 2 before proceeding with the installation

![Integration Diagram](figures/virtual-clusters.jpeg)

### Installation 
1. Login to the Rocky Linux installed virtual machine. This is the installation host and the head node for the virtual cluster
2. Move to the rocky user if you are in a different user. ```sudo su - rocky```
3. If you have not already done, create an openrc fire for your jetsream2 account by following the [Jestream 2 Documentation](https://docs.jetstream-cloud.org/ui/cli/openrc/)
4. Copy the generated openrc file to the home directory of rocky user
5. Clone the [XCRI Virtual Cluster repository](https://github.com/XSEDE/CRI_Jetstream_Cluster) 
6. If you'd like to modify your cluster, now is a good time!

    * The number of nodes can be set in the slurm.conf file, by editing
      the NodeName and PartitionName line.
    * If you'd like to change the default node size, the ```node_size=```line
      in ```slurm_resume.sh``` must be changed.
    * If you'd like to enable any specific software, you should edit
      ```compute_build_base_img.yml```. The task named "install basic packages"
      can be easily extended to install anything available from a yum
      repository. If you need to *add* a repo, you can copy the task
      titled "Add OpenHPC 1.3.? Repo". For more detailed configuration,
      it may be easiest to build your software in /export on the headnode,
      and only install the necessary libraries via the compute_build_base_img
      (or ensure that they're available in the shared filesystem).
    * For other modifications, feel free to get in touch!
7. Now you are all set to install the cluster. Run ```cluster_create_local.sh``` as the rocky user. This will take around
   30 minutes to fully install the cluster.
8. If you need to destroy the cluster, Run ```cluster_destroy_local.sh```. This will decommission the SLURM cluster and any
   runnning compute nodes. If you need to delete the headnode as well, pass the -d paramaeter to cluster destroy script


### Usage note:
Slurm will run the suspend/resume scripts in response to
```
scontrol update nodename=compute-[0-1] state=power_down
```
or
```
scontrol update nodename=compute-[0-1] state=power_up
```

If compute instances got stuck in a bad state, it's often helpful to
cycle through the following:

```
scontrol update nodename=compute-[?] state=down reason=resetting
```
```
scontrol update nodename=compute-[?] state=idle
```

or to re-run the suspend/resume scripts as above (if the instance
power state doesn't match the current state as seen by slurm). Instances
in a failed state within Openstack may simply be deleted, as they will
be built anew by slurm the next time they are needed.


This work supported by [![NSF-1548562](https://img.shields.io/badge/NSF-1548562-blue.svg)](https://nsf.gov/awardsearch/showAward?AWD_ID=1548562)
