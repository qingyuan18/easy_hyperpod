#!/bin/bash


set -e
set -x

PEM_FILE="pub.pem"
PEM_PRIV_FILE="priv.pem"

main() {
  if [[ ! -f $PEM_FILE ]]; then
    echo "Shared user file $PEM_FILE does not exist. Skipping adding ssh pem."
    exit 0
  fi

  {
  cat $PEM_FILE|tr '\n' ' '
  } >> /home/ubuntu/.ssh/authorized_keys
  cp $PEM_PRIV_FILE  /home/ubuntu/.ssh/id_rsa
  chmod 400 /home/ubuntu/.ssh/id_rsa
  chown ubuntu:ubuntu /home/ubuntu/.ssh/id_rsa
  #echo "ssh-rsa ">> /home/ubuntu/.ssh/authorized_keys
  #cat $PEM_FILE >> /home/ubuntu/.ssh/authorized_keys
  #echo " 203.pem "  >> /home/ubuntu/.ssh/authorized_keys
}

main "$@"

