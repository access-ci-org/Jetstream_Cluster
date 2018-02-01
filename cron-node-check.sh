#!/bin/bash

sinfo_check=$(sinfo | grep -iE "drain|down")

#mail_domain=$(curl -s https://ipinfo.io/hostname)
mail_domain=$(host $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4) | sed 's/.*pointer \(.*\)./\1/') 

email_addr=""

try_count=0
declare -i try_count
until [[ -n $mail_domain || $try_count -ge 10 ]];
do
 sleep 3
 mail_domain=$(curl -s https://ipinfo.io/hostname)
 try_count=$try_count+1
 echo $mail_domain, $try_count
done

if [[ $try_count -ge 10 ]]; then
 echo "failed to get domain name!"
 exit 1
fi

if [[ -n $sinfo_check ]]; then
  echo $sinfo_check | mailx -r "node-check@$mail_domain" -s "NODE IN BAD STATE - $mail_domain" $email_addr
#  echo "$sinfo_check  mailx -r "node-check@$mail_domain" -s "NODE IN BAD STATE - $mail_domain" $email_addr" # TESTING LINE
fi
