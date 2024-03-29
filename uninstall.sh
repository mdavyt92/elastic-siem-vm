#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "##########################################################################"
echo "## WARNING: THIS WILL DELETE ALL ELK CONTAINERS AND CONFIGURATION FILES ##"
echo "##########################################################################"

read -p "Are you sure you want to continue? Type 'YES' " -r
echo
if [[ $REPLY != "YES" ]]
then
  echo "Exiting..."
  exit 1
fi

detect_OS() {
  echo "Detecting OS..."
  source /etc/os-release
  OS_FAMILY=$ID
  echo "OS detected: $OS_FAMILY"
}

remove_arch() {
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

  echo "Deleting Apache configuration"
  rm -f /etc/apache2/sites-available/kibana.conf
  rm -f /etc/apache2/sites-enabled/kibana.conf
  rm -rf /etc/apache2/certs

  echo "Removing service files"
  rm -f /etc/systemd/system/elasticsearch.service
  rm -f /etc/systemd/system/logstash.service
  rm -f /etc/systemd/system/kibana.service
  rm -f /etc/systemd/system/elastalert.service
  rm -f /etc/systemd/system/filebeat.service
  rm -f /etc/systemd/system/wazuh.service
}

uninstall_ubuntu() {

  apt remove docker.io docker-compose apache2
  apt autoremove
}

uninstall_centos() {
  yum remove docker
  yum remove docker-ce
  yum remove docker-compose
  yum remove httpd
  yum remove ufw
}

# Pre uninstall
detect_OS

# Remove containers & config files
remove_arch

# Remove installed packages
uninstall_$OS_FAMILY
