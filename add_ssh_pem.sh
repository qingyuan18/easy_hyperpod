#!/bin/bash


set -e
set -x

PEM_FILE="203.pem"

main() {
  if [[ ! -f $PEM_FILE ]]; then
    echo "Shared user file $PEM_FILE does not exist. Skipping adding ssh pem."
    exit 0
  fi
  
  echo "ssh-rsa ">> /home/ubuntu/.ssh/authorized_keys
  cat $PEM_FILE >> /home/ubuntu/.ssh/authorized_keys
  echo " 203.pem "  >> /home/ubuntu/.ssh/authorized_keys
}

main "$@"

