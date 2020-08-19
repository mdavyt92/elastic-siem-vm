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

echo "Copying docker files..."
if [ -d /opt/docker-compose ]; then
  rm -rf /opt/docker-compose
fi
cp -r docker-compose /opt/docker-compose

echo "Setting Elastic password..."
ELASTIC_PASSWORD=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo`
echo "ELASTIC_PASSWORD=$ELASTIC_PASSWORD" | tee -a /opt/docker-compose/.env

echo "Generating Kibana encryption key..."
KIBANA_ENCRYPTION_KEY=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo`
echo "KIBANA_ENCRYPTION_KEY=$KIBANA_ENCRYPTION_KEY" | tee -a /opt/docker-compose/.env

echo "Copying service..."
cp elastic.service /etc/systemd/system/

echo "Generating Elastic certificates..."
docker-compose -f /opt/docker-compose/create-certs.yml run --rm create_certs

echo "Reloading systemctl daemon..."
systemctl daemon-reload

echo "Enabling service..."
systemctl enable elastic

echo "Starting service..."
systemctl start elastic

echo "Setting password for kibana_system user..."
docker exec elasticsearch bash -c "curl --user elastic:$ELASTIC_PASSWORD --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt  -XPOST -H 'Content-Type: application/json' https://localhost:9200/_security/user/kibana_system/_password -d '{ \"password\": \"$ELASTIC_PASSWORD\" }'"
