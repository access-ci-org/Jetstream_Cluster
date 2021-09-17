#!/bin/bash

show_help() {
  echo "Options:
        VNC_COMMAND: required, program to start undernead VNC - executed inside xterm
	VNC_PASSWORD: required, password for VNC session

Usage: $0 -p [VNC_PASSWORD] -c [VNC_COMMAND]"
}

OPTIND=1

vnc_command=""
vnc_password=""

while getopts ":hhelp:p:c:" opt; do
  case ${opt} in
    h|help|\?) show_help
      exit 0
      ;;
    p) vnc_password=${OPTARG}
      ;;
    c) vnc_command=${OPTARG}
      ;;
    :) echo "Option -$OPTARG requires an argument."
      exit 1
      ;;

  esac
done


mkdir -p ${PWD}/.vnc

echo ${vnc_password} | vncpasswd -f > ${PWD}/.vnc/passwd

echo job $JOB_ID execution at: `date`

#rm -f $HOME/.envision_address $HOME/.envision_display $HOME/.envision_vnc_port $HOME/.envision_job_id $HOME/.envision_job_start $HOME/.envision_job_duration $HOME/.envision_status

# our node name
NODE_HOSTNAME=`hostname -s`
echo "running on node $NODE_HOSTNAME"

# VNC server executable
VNCSERVER_BIN=`which vncserver`
echo "using default VNC server $VNCSERVER_BIN"

# set memory limits to 95% of total memory to prevent node death
NODE_MEMORY=`free -k | grep ^Mem: | awk '{ print $2; }'`
NODE_MEMORY_LIMIT=`echo "0.95 * $NODE_MEMORY / 1" | bc`
ulimit -v $NODE_MEMORY_LIMIT -m $NODE_MEMORY_LIMIT
echo "memory limit set to $NODE_MEMORY_LIMIT kilobytes"

# Check whether a vncpasswd file exists.  If not, complain and exit.
if [ \! -e ${PWD}/.vnc/passwd ] ; then
    echo
    echo "=================================================================="
    echo "   You must run 'vncpasswd' once before launching a vnc session"
    echo "=================================================================="
    echo
    exit 1
fi

# launch VNC session
VNC_DISPLAY=`$VNCSERVER_BIN -PasswordFile ${PWD}/.vnc/passwd 2>&1 | grep desktop | awk -F: '{print $3}'`
echo "got VNC display :$VNC_DISPLAY"

# todo: make sure this is a valid display, and that it is 1 or 2, since those are the only displays forwarded
# using our iptables scripts

if [ x$VNC_DISPLAY == "x" ]; then
    echo
    echo "===================================================="
    echo "   Error launching vncserver: $VNCSERVER on display $VNC_DISPLAY"
    echo "   Please contact the gateway administrator for help"
    echo "   including the Job ID and Experiment name."
    echo "===================================================="
    echo
    exit 1
fi

LOCAL_VNC_PORT=`expr 5900 + $VNC_DISPLAY`
echo "local (compute node) VNC port is $LOCAL_VNC_PORT"

#jec - will have to work this up for airavata, probably
## fire up websockify to turn the vnc session connection into a websocket connection

##CAREFUL! THE FOLLOWING RELIES ON COMPUTE NODE NAMES BEING ONLY prefix-0 to prefix-9
## IF YOU ADD MORE NODES THINGS WILL BREAK - JECOULTE jecoulte
LOGIN_VNC_PORT=${NODE_HOSTNAME: -1:1}
#if `echo ${NODE_HOSTNAME} | grep -q c5`; then 
#    # on a c500 node, bump the login port 
#    LOGIN_VNC_PORT=$(($LOGIN_VNC_PORT + 400))
#fi
LOGIN_VNC_PORT=$(($LOGIN_VNC_PORT + 22000))
echo "got login node VNC port $LOGIN_VNC_PORT"

#Uncommenting this allows local access from a VNC client - also the final line tagged VNCCLIENTACC
#ssh -q -M -S .${SLURM_JOB_ID}_ssh -f -g -N -R $LOGIN_VNC_PORT:$NODE_HOSTNAME:$LOCAL_VNC_PORT delta-vc -o ExitOnForwardFailure=yes

#WEBSOCKIFY_COMMAND="websockify -D delta-vc:$LOGIN_VNC_PORT localhost:$LOCAL_VNC_PORT"

WEBSOCKIFY_COMMAND="websockify -D --log-file=\$(mktemp /tmp/websockify.XXXX) --cert=/etc/letsencrypt/live/js-171-214.jetstream-cloud.org/fullchain.pem --key=/etc/letsencrypt/live/js-171-214.jetstream-cloud.org/privkey.pem $LOGIN_VNC_PORT $NODE_HOSTNAME:$LOCAL_VNC_PORT"
echo "Running: ${WEBSOCKIFY_COMMAND}"
WEBSOCKIFY_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null delta-vc "${WEBSOCKIFY_COMMAND}" 2>&1 )
echo ${WEBSOCKIFY_OUTPUT}

echo -e " <!DOCTYPE html>
<html>
<body>

<!--
 Your VNC server is now running!
Connect via your vnc viewer to: js-171-214.jetstream-cloud.org:$LOGIN_VNC_PORT
-->
<a href='https://delta-topology.org/static/vnc/noVNC/vnc.html?host=js-171-214.jetstream-cloud.org&port=$LOGIN_VNC_PORT&autoconnect=true&password=${vnc_password}&encrypt=1'> Open VNC Connection </a>
</body>
</html> " > ${SLURM_JOB_NAME}.html

## Optional text for when the tunnel option is used
#Alternately, connect via SSH tunnel: 
#On your local machine, create a tunnel through the headnode via:
#ssh -L $LOGIN_VNC_PORT:127.0.0.1:${LOGIN_VNC_PORT} YOUR-USERNAME@js-171.214.jetstream-cloud.org
#and then run (on your local machine)
#vncviewer localhost:$LOGIN_VNC_PORT


scp ${SLURM_JOB_NAME}.html pga@delta-portal:/var/www/portals/django-delta/static/vnc/

# set display for X applications
export DISPLAY=":$VNC_DISPLAY"

# run an xterm for the user; execution will hold here
#xterm -r -ls -geometry 80x24+10+10 -title '*** Exit this window to kill your VNC server ***' &
#xterm -e /bin/bash -l -c "/opt/ohpc/pub/apps/visit/bin/visit -o ../visit_tutorial/aneurism.visit" -title '*** Exit this window to kill your VNC server ***'
#xterm -e "/opt/ohpc/pub/apps/visit/bin/visit -o ../visit_tutorial/aneurysm.visit"
#xterm -e "/data/Apps/paraview/ParaView-5.9.0-MPI-Linux-Python3.8-64bit/bin/paraview"
xterm -e "${vnc_command}"

# job is done!

echo "Killing VNC server"
vncserver -kill $DISPLAY

#Now, time to kill the websockify process on the headnode
WEBSOCKIFY_REGEX="$NODE_HOSTNAME:$LOCAL_VNC_PORT"
echo "Killing websockify via pkill -f ${WEBSOCKIFY_REGEX}"
KILL_WEBSOCKIFY=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null delta-vc "pkill -f ${WEBSOCKIFY_REGEX}" 2>&1 )
echo "${KILL_WEBSOCKIFY}"

# wait a brief moment so vncserver can clean up after itself
sleep 1

echo job $_SLURM_JOB_ID execution finished at: `date`
#Uncommenting this allows local access from a VNC client - VNCCLIENTACC
#ssh -S .${SLURM_JOB_ID}_ssh -O exit delta-vc
