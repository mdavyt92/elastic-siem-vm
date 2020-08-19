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

echo "Copying Elastic Stack files..."
cp -r elastic /opt/elastic

echo "Copying Docker files..."
if [ -d /opt/docker-compose ]; then
  rm -rf /opt/docker-compose
fi
cp -r docker-compose /opt/docker-compose

echo "Generating Elastic certificates..."
docker-compose -f /opt/docker-compose/create-certs.yml run --rm create_certs

echo "Starting Elasticsearch..."
cd /opt/docker-compose
docker-compose up -d elasticsearch

echo "Setting passwords for built-in users..."
docker exec elasticsearch bin/elasticsearch-setup-passwords auto --batch |
  grep PASSWORD |
  sed 's/PASSWORD //' |
  sed 's/ = /_password=/' |
  tee /opt/elastic/.passwords

source /opt/elastic/.passwords

echo "Configuring password for Kibana..."
sed -i "s/%KIBANA_PASS%/$kibana_system_password/" /opt/elastic/kibana/config/kibana.yml

echo "Configuring encryption key for Kibana..."
KIBANA_ENCRYPTION_KEY=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo`
sed -i "s/%KIBANA_ENCRYPTION_KEY%/$KIBANA_ENCRYPTION_KEY/" /opt/elastic/kibana/config/kibana.yml

echo "Copying services..."
cp services/*.service /etc/systemd/system/

echo "Reloading systemctl daemon..."
systemctl daemon-reload

echo "Enabling services..."
systemctl enable elasticsearch
systemctl enable kibana
systemctl enable logstash

echo "Starting services..."
systemctl start elasticsearch
systemctl start kibana
systemctl start logstash
