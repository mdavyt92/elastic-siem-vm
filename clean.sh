#!/bin/bash

docker stop $(docker ps -a -q)
docker rm -f $(docker ps -a -q)
docker volume rm $(docker volume ls -q)
rm -rf /opt/elastic
rm -rf /opt/docker-compose
rm -f /etc/systemd/system/elasticsearch.service
rm -f /etc/systemd/system/logstash.service
rm -f /etc/systemd/system/kibana.service
