#!/bin/bash
echo "##########################################################################"
echo "## WARNING: THIS WILL DELETE ALL ELK CONTAINERS AND CONFIGURATION FILES ##"
echo "##########################################################################"

read -p "Are you sure you want to continue? Type 'YES' " -r
echo
if [[ $REPLY != "YES"  ]]
then
  echo "Exiting..."
  exit
else

echo "Stopping all containers"
docker stop $(docker ps -a -q)

echo "Removing all containers"
docker rm -f $(docker ps -a -q)

echo "Deleting all volumes"
docker volume rm $(docker volume ls -q)

echo "Removing UFW-Docker configuration"
sed -i '/BEGIN UFW AND DOCKER/,/END UFW AND DOCKER/ d' /etc/ufw/after.rules

echo "Deleting all files"
rm -rf /opt/elastic
rm -rf /opt/docker-compose

echo "Removing service files"
rm -f /etc/systemd/system/elasticsearch.service
rm -f /etc/systemd/system/logstash.service
rm -f /etc/systemd/system/kibana.service
