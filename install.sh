#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

DIR=$(dirname $0)

echo "Updating package list..."
apt -y update

echo "Installing docker..."
apt -y install docker.io docker-compose

if [ -e /opt/elastic ]
then
  read -p "Directory /opt/elastic exists. Do you want to delete it? " -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]
  then
    rm -rf /opt/elastic
  else
    echo "Operation cancelled"
    exit
  fi
fi

echo "Copying files..."
cp -r elastic /opt/elastic

echo "Copying service..."
cp elastic.service /etc/systemd/system/

echo "Reloading systemctl daemon..."
systemctl daemon-reload

echo "Enabling service..."
systemctl enable elastic

echo "Starting service..."
systemctl start elastic
