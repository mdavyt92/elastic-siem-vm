#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

install_docker() {
  echo "Updating package list..."
  apt -y update

  echo "Installing docker..."
  apt -y install docker.io docker-compose
}

wait_elastic() {
  echo -n "Waiting for Elasticsearch to be ready..."
  while true
  do
    echo -n "."
    docker exec es01 curl https://es01:9200 -k >/dev/null 2>&1
    [ $? -eq 0 ] && echo "done" && return || sleep 5
  done
}

copy_files() {
  echo "Copying Elastic Stack files..."
  if [ -e /opt/elastic ]
  then
    read -p "Directory /opt/elastic exists. Do you want to delete it? " -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
      rm -rf /opt/elastic
      cp -r elastic /opt/elastic
    else
      echo "Keeping old files"
    fi
  else
    cp -r elastic /opt/elastic
  fi

  echo "Copying Docker files..."
  if [ -d /opt/docker-compose ]; then
    rm -rf /opt/docker-compose
  fi
  cp -r docker-compose /opt/docker-compose
}

install_elasticsearch() {
  pushd /opt/docker-compose

  echo "Generating Elastic certificates..."
  docker-compose -f create-certs.yml run --rm create_certs

  echo "Starting Elasticsearch..."
  docker-compose up -d es01
  docker-compose up -d es02
  docker-compose up -d es03

  wait_elastic

  echo "Setting passwords for built-in users..."
  docker exec es01 bin/elasticsearch-setup-passwords auto --batch |
    grep PASSWORD |
    sed 's/PASSWORD //' |
    sed 's/ = /_password=/' |
    tee /opt/elastic/.passwords
  chmod 0400 /opt/elastic/.passwords

  echo "Removing default password..."
  sed -i '/ELASTIC_PASSWORD/d' /opt/docker-compose/docker-compose.yml

  popd
}

create_roles_users_beats(){
  echo "Creating roles and users for each beats type..."
  source /opt/elastic/.passwords

  wait_elastic

  beats=(
    filebeat
    metricbeat
    packetbeat
    winlogbeat
    auditbeat
    heartbeat
    functionbeat
  )

  for beat in ${beats[@]}; do

    echo "Creating ${beat}_writer role..."
    docker exec es01 curl \
      --silent \
      --user elastic:$elastic_password \
      --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt \
      -H "Content-Type: application/json" \
      -XPOST "https://es01:9200/_xpack/security/role/${beat}_writer" \
      -d"
      {
        \"cluster\": [ \"monitor\", \"read_ilm\" ],
        \"indices\": [
          {
            \"names\": [ \"${beat}-*\" ],
            \"privileges\": [ \"create_doc\", \"view_index_metadata\", \"create_index\" ]
          }
        ]
      }"

    echo "Creating ${beat}_user user..."
    beatpass=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo`
    docker exec es01 curl \
      --silent \
      --user elastic:$elastic_password \
      --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt \
      -H "Content-Type: application/json" \
      -XPOST "https://es01:9200/_security/user/${beat}_user" \
      -d "
      {
        \"password\": \"$beatpass\",
        \"roles\": [ \"${beat}_writer\" ]
      }"
    echo; echo "${beat}_user_password=$beatpass" | tee -a /opt/elastic/.passwords

    echo "Creating ${beat}_setup role..."
    docker exec es01 curl \
      --silent \
      --user elastic:$elastic_password \
      --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt \
      -H "Content-Type: application/json" \
      -XPOST "https://es01:9200/_xpack/security/role/${beat}_setup" \
      -d"
      {
        \"cluster\": [\"monitor\", \"manage_ilm\"],
        \"indices\": [
          {
            \"names\": [ \"${beat}-*\" ],
            \"privileges\": [\"manage\"]
          }
        ]
      }"

    echo "Creating ${beat}_setup_user user..."
    beatpass=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo`
    docker exec es01 curl \
      --silent \
      --user elastic:$elastic_password \
      --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt \
      -H "Content-Type: application/json" \
      -XPOST "https://es01:9200/_security/user/${beat}_setup_user" \
      -d "
      {
        \"password\": \"$beatpass\",
        \"roles\": [ \"${beat}_setup\", \"kibana_admin\", \"ingest_admin\" ]
      }"
    echo; echo "${beat}_setup_user_password=$beatpass" | tee -a /opt/elastic/.passwords

  done
}

install_kibana() {
  read -p "Do you want to install Kibana? " -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
    return
  fi

  pushd /opt/docker-compose

  source /opt/elastic/.passwords

  wait_elastic

  echo "Configuring new superuser for Kibana..."
  read -p "Username: " kibana_user
  while true; do
    read -s -p "Password: " kibana_password
    echo
    read -s -p "Password (again): " kibana_password2
    echo
    [ "$kibana_password" = "$kibana_password2" ] && break
    echo "Please try again"
  done
  docker exec es01 curl \
    --user elastic:$elastic_password \
    --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt \
    -H "Content-Type: application/json" \
    -XPOST "https://es01:9200/_security/user/$kibana_user" \
    -d "
    {
      \"password\": \"$kibana_password\",
      \"roles\": [ \"superuser\" ]
    }"

  echo "Configuring password for Kibana..."
  sed -i "s/%KIBANA_PASS%/$kibana_system_password/" /opt/elastic/kibana/config/kibana.yml

  echo "Configuring encryption key for Kibana..."
  KIBANA_ENCRYPTION_KEY=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo`
  sed -i "s/%KIBANA_ENCRYPTION_KEY%/$KIBANA_ENCRYPTION_KEY/" /opt/elastic/kibana/config/kibana.yml

  echo "Starting Kibana..."
  docker-compose up -d kibana

  popd

  KIBANA_INSTALLED=true
}

install_logstash() {
  read -p "Do you want to install Logstash? " -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
    return
  fi

  pushd /opt/docker-compose

  source /opt/elastic/.passwords

  wait_elastic

  echo "Creating role for Logstash user..."
  docker exec es01 curl \
    --user elastic:$elastic_password \
    --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt \
    -H "Content-Type: application/json" \
    -XPOST "https://es01:9200/_xpack/security/role/logstash_writer" \
    -d'
    {
      "cluster": ["manage_index_templates", "monitor", "manage_ilm"],
      "indices": [
        {
          "names": [ "logstash-*" ],
          "privileges": ["write","create","delete","create_index","manage","manage_ilm"]
        }
      ]
    }'

  echo "Creating logstash_internal user"
  logstash_internal_password=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo`
  docker exec es01 curl \
    --user elastic:$elastic_password \
    --cacert /usr/share/elasticsearch/config/certificates/ca/ca.crt \
    -H "Content-Type: application/json" \
    -XPOST "https://es01:9200/_security/user/logstash_internal" \
    -d "
    {
      \"password\": \"$logstash_internal_password\",
      \"roles\": [ \"logstash_writer\" ]
    }"

  echo "logstash_internal_password=$logstash_internal_password" | tee -a /opt/elastic/.passwords

  echo "Configuring password for Logstash..."
  sed -i "s/%LOGSTASH_PASS%/$logstash_internal_password/" /opt/elastic/logstash/pipeline/*.conf

  echo "Starting Logstash..."
  docker-compose up -d logstash

  popd

  LOGSTASH_INSTALLED=true
}

install_services() {
  read -p "Do you want to install services for elasticsearch, logstash and kibana? " -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
    return
  fi

  echo "Copying services..."
  cp services/elasticsearch.service /etc/systemd/system/
  $KIBANA_INSTALLED && cp services/kibana.service /etc/systemd/system/
  $LOGSTASH_INSTALLED && cp services/logstash.service /etc/systemd/system/

  echo "Reloading systemctl daemon..."
  systemctl daemon-reload

  echo "Stopping containers..."
  pushd /opt/docker-compose
  docker-compose down
  popd

  echo "Starting and enabling services..."
  systemctl enable elasticsearch && systemctl start elasticsearch
  $KIBANA_INSTALLED && systemctl enable kibana && systemctl start kibana
  $LOGSTASH_INSTALLED && systemctl enable logstash && systemctl start logstash
}

install_apache(){
  read -p "Do you want to install and configure an Apache Reverse Proxy? " -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
    return
  fi

  echo "Installing apache..."
  apt install apache2

  echo "Removing default configuration..."
  rm -f /etc/apache2/sites-enabled/*

  echo "Copying configuration files..."
  cp apache/sites-available/* /etc/apache2/sites-available/
  cp apache/conf-available/* /etc/apache2/conf-available/

  echo "Generating self-signed certificate..."
  mkdir /etc/apache2/certs
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/apache2/certs/selfsigned.key -out /etc/apache2/certs/selfsigned.crt

  echo "Select your preferred TLS configuration:"
  tls_high="Modern (highest security, highest compatibility): Supports Firefox 63, Android 10.0, Chrome 70, Edge 75, Java 11, OpenSSL 1.1.1, Opera 57, and Safari 12.1"
  tls_med="Intermediate (recommended for most cases): Supports Firefox 27, Android 4.4.2, Chrome 31, Edge, IE 11 on Windows 7, Java 8u31, OpenSSL 1.0.1, Opera 20, and Safari 9"
  tls_low="Old (lowest security, highest compatibility): Supports Firefox 1, Android 2.3, Chrome 1, Edge 12, IE8 on Windows XP, Java 6, OpenSSL 0.9.8, Opera 5, and Safari 1"
  select tlslevel in "$tls_high" "$tls_med" "$tls_low"; do
    case $tlslevel in
      ${tls_high} ) TLS_LEVEL="high"; break;;
      ${tls_med} ) TLS_LEVEL="medium"; break;;
      ${tls_low} ) TLS_LEVEL="low"; break;;
      * ) echo "Please select a valid option.";
    esac
  done

  echo "Configuring selected TLS profile..."
  sed -i "s/%TLS_LEVEL%/$TLS_LEVEL/" /etc/apache2/sites-available/kibana.conf

  echo "Enabling required modules..."
  a2enmod ssl rewrite headers socache_shmcb proxy proxy_http

  echo "Enabling site..."
  ln -s /etc/apache2/sites-available/kibana.conf /etc/apache2/sites-enabled/kibana.conf

  echo "Restarting apache..."
  systemctl restart apache2

  echo "Allowing Apache through the firewall..."
  ufw allow http
  ufw allow https
}

configure_firewall(){
  echo -n "Getting Elastic subnet..."
  DOCKER_SUBNET=`docker network inspect elastic_elknet | grep -oP '"Subnet": "\K\d+\.\d+\.\d+\.\d+\/\d+'`
  echo $DOCKER_SUBNET

  echo "Configuring UFW-DOCKER rules..."
  cat <<EOF | tee -a /etc/ufw/after.rules

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
# Allow everything coming from the Docker Containers
-A DOCKER-USER -j RETURN -s %DOCKER_SUBNET%

# Custom rules
-A DOCKER-USER -j ufw-user-forward

# Deny everything going to the Docker Containers
-A DOCKER-USER -j DROP -p tcp -d %DOCKER_SUBNET%
-A DOCKER-USER -j DROP -p udp -d %DOCKER_SUBNET%

-A DOCKER-USER -j RETURN
COMMIT
# END UFW AND DOCKER
EOF

  sed -i "s#%DOCKER_SUBNET%#$DOCKER_SUBNET#" /etc/ufw/after.rules

  echo "Configuring Firewall policy..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed

  echo "Allowing SSH Connections through the firewall..."
  ufw allow ssh

  read -p "Allow Elasticsearch to be accessed remotely? " -r
  if  [[ $REPLY =~ ^[Yy]$ ]]
  then
    ufw route allow proto tcp from any to $DOCKER_SUBNET port 9200
  fi

  if $LOGSTASH_INSTALLED; then
    read -p "Allow Logstash to be accessed remotely? " -r
    if  [[ $REPLY =~ ^[Yy]$ ]]
    then
      ufw route allow proto tcp from any to $DOCKER_SUBNET port 5044
    fi
  fi

  if $KIBANA_INSTALLED; then
    read -p "Allow Kibana to be accessed remotely? (Not recommended if you installed Apache) " -r
    if  [[ $REPLY =~ ^[Yy]$ ]]
    then
      ufw route allow proto tcp from any to $DOCKER_SUBNET port 5601
    fi
  fi

  echo "Enabling firewall..."
  ufw enable

  echo "Restarting UFW..."
  systemctl restart ufw
}

# Pre installation
install_docker
copy_files

# ELK Stack
install_elasticsearch
install_kibana
install_logstash

# Beats users and roles
create_roles_users_beats

# Services for starting/stopping the stack
install_services

# Apache Reverse Proxy
install_apache

# Firewall
configure_firewall
