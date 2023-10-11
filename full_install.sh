#!/bin/bash
setenforce 0
yum install wget -y
export DEBIAN_FRONTEND=noninteractive
export LOCAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

export NODE_DOWNLOAD_URL='https://github.com/prometheus/node_exporter/releases/download/v1.6.1/node_exporter-1.6.1.linux-amd64.tar.gz'
export NODE_FILE_NAME='node_exporter-1.6.1.linux-amd64.tar.gz'
export NODE_DIR_NAME='node_exporter-1.6.1.linux-amd64/'

export PROME_DOWNLOAD_URL='https://github.com/prometheus/prometheus/releases/download/v2.47.0/prometheus-2.47.0.linux-amd64.tar.gz'
export PROME_FILE_NAME='prometheus-2.47.0.linux-amd64.tar.gz'
export PROME_DIR_NAME='prometheus-2.47.0.linux-amd64/'

export PROME_REMOTE_WRITE_URL='https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-8beedde5-482e-450c-bd6d-3477ddfa7f4e/api/v1/remote_write'
export PROME_REGION='us-east-1'

rm -fr /usr/local/bin/node_exporter
rm -fr /lib/systemd/system/node_exporter.service

yum update -y
yum upgrade -y
wget $NODE_DOWNLOAD_URL
tar xvf $NODE_FILE_NAME
cd $NODE_DIR_NAME 
mv node_exporter /usr/local/bin
useradd node_exporter --no-create-home --shell /bin/false

cat <<EOL > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
Restart=on-failure
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100

[Install]
WantedBy=multi-user.target
EOL

# Enable and start the node_exporter service

systemctl daemon-reload
systemctl start node_exporter
systemctl enable node_exporter

rm -fr /etc/prometheus/
rm -fr /var/lib/prometheus
rm -fr /usr/local/bin/prometheus
rm -fr /usr/local/bin/promtool
rm -fr /lib/systemd/system/prometheus.service

groupadd --system prometheus
useradd -s /sbin/nologin --system -g prometheus prometheus

mkdir /var/lib/prometheus
mkdir /etc/prometheus

wget $PROME_DOWNLOAD_URL
tar xvfz $PROME_FILE_NAME
cd $PROME_DIR_NAME
mv prometheus /usr/local/bin/
mv promtool /usr/local/bin

chown prometheus:prometheus /usr/local/bin/prometheus
chown prometheus:prometheus /usr/local/bin/promtool

mv consoles /etc/prometheus/
mv console_libraries/ /etc/prometheus/

cat <<EOL > /etc/prometheus/node_exporter_recording_rules.yml
"groups":
- "name": "node-exporter.rules"
  "rules":
  - "expr": |
      count without (cpu) (
        count without (mode) (
          node_cpu_seconds_total{job="node"}
        )
      )
    "record": "instance:node_num_cpu:sum"
  - "expr": |
      1 - avg without (cpu, mode) (
        rate(node_cpu_seconds_total{job="node", mode="idle"}[1m])
      )
    "record": "instance:node_cpu_utilisation:rate1m"
  - "expr": |
      (
        node_load1{job="node"}
      /
        instance:node_num_cpu:sum{job="node"}
      )
    "record": "instance:node_load1_per_cpu:ratio"
  - "expr": |
      1 - (
        node_memory_MemAvailable_bytes{job="node"}
      /
        node_memory_MemTotal_bytes{job="node"}
      )
    "record": "instance:node_memory_utilisation:ratio"
  - "expr": |
      rate(node_vmstat_pgmajfault{job="node"}[1m])
    "record": "instance:node_vmstat_pgmajfault:rate1m"
  - "expr": |
      rate(node_disk_io_time_seconds_total{job="node", device!=""}[1m])
    "record": "instance_device:node_disk_io_time_seconds:rate1m"
  - "expr": |
      rate(node_disk_io_time_weighted_seconds_total{job="node", device!=""}[1m])
    "record": "instance_device:node_disk_io_time_weighted_seconds:rate1m"
  - "expr": |
      sum without (device) (
        rate(node_network_receive_bytes_total{job="node", device!="lo"}[1m])
      )
    "record": "instance:node_network_receive_bytes_excluding_lo:rate1m"
  - "expr": |
      sum without (device) (
        rate(node_network_transmit_bytes_total{job="node", device!="lo"}[1m])
      )
    "record": "instance:node_network_transmit_bytes_excluding_lo:rate1m"
  - "expr": |
      sum without (device) (
        rate(node_network_receive_drop_total{job="node", device!="lo"}[1m])
      )
    "record": "instance:node_network_receive_drop_excluding_lo:rate1m"
  - "expr": |
      sum without (device) (
        rate(node_network_transmit_drop_total{job="node", device!="lo"}[1m])
      )
    "record": "instance:node_network_transmit_drop_excluding_lo:rate1m"
EOL

cat <<EOL > /etc/prometheus/prometheus.yml
global:
  scrape_interval: 60s 
  evaluation_interval: 60s 

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          # - alertmanager:9093

rule_files:
  - "node_exporter_recording_rules.yml"

scrape_configs:

  - job_name: "node"
    static_configs:
      - targets: ['${LOCAL_IP}:9100']

  - job_name: "prometheus"
    static_configs:
      - targets: ['${LOCAL_IP}:9090']

remote_write:
  - url: "${PROME_REMOTE_WRITE_URL}"
    sigv4:
      region: ${PROME_REGION}
    queue_config:
      max_samples_per_send: 1000
      max_shards: 200
      capacity: 2500
EOL

cat <<EOL > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file /etc/prometheus/prometheus.yml \
    --storage.tsdb.path /var/lib/prometheus/ \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOL


chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus 
firewall-cmd --permanent --zone=public --add-port=9090/tcp
firewall-cmd --reload
chown node_exporter:node_exporter /usr/local/bin/node_exporter
systemctl restart docker
echo "Se finaliza"