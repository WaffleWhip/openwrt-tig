#!/bin/bash

# ================= CONFIGURATION =================
CT_ID=111
CT_HOSTNAME="tig-monitoring"
CT_PASS="telkom123"
CT_IP="100.0.0.111/24"
CT_GW="100.0.0.1"
CT_BRIDGE="vmbrlan"
STORAGE_ROOT="local-lvm"
STORAGE_TPL="local"

# InfluxDB v2 Config
ORG="my-org"
BUCKET="collectd"
TOKEN="telkom123telkom123"
# ===============================================

# --- Styling & Logging ---
log_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

echo "========================================================"
echo "      TIG STACK AUTOMATED PROVISIONING (LXC)"
echo "========================================================"

log_info "Step 1/6: Provisioning LXC Container (Debian 13)..."
TEMPLATE=$(pvesm list $STORAGE_TPL --content vztmpl | grep "debian-13" | awk '{print $1}' | tail -n 1)

# Cleanup existing container if exists
if pct status $CT_ID >/dev/null 2>&1; then
    log_info "Detected existing container with ID $CT_ID. Initiating teardown..."
    pct stop $CT_ID >/dev/null 2>&1
    pct destroy $CT_ID >/dev/null 2>&1
    log_success "Previous container destroyed."
fi

pct create $CT_ID $TEMPLATE --hostname $CT_HOSTNAME --password $CT_PASS --cores 2 --memory 2048 --swap 512 --net0 name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP,gw=$CT_GW --storage $STORAGE_ROOT --features nesting=1 --unprivileged 1 --start 1
sleep 5

log_info "Step 2/6: Installing Docker Engine & Dependencies..."
pct exec $CT_ID -- bash -c "apt-get update && apt-get install -y curl jq"
pct exec $CT_ID -- bash -c "curl -fsSL https://get.docker.com | sh"

log_info "Step 3/6: Structuring Directories & Setting Permissions..."
pct exec $CT_ID -- mkdir -p /root/tig-stack/grafana_data
pct exec $CT_ID -- mkdir -p /root/tig-stack/grafana_provisioning/datasources
pct exec $CT_ID -- mkdir -p /root/tig-stack/grafana_provisioning/dashboards
pct exec $CT_ID -- mkdir -p /root/tig-stack/grafana_dashboards

# Fix Grafana Permissions (UID 472)
pct exec $CT_ID -- chown -R 472:472 /root/tig-stack/grafana_data
pct exec $CT_ID -- chown -R 472:472 /root/tig-stack/grafana_provisioning
pct exec $CT_ID -- chown -R 472:472 /root/tig-stack/grafana_dashboards

# Download Types.db (Required for Telegraf Collectd input)
pct exec $CT_ID -- curl -s -o /root/tig-stack/types.db https://raw.githubusercontent.com/collectd/collectd/master/src/types.db

log_info "Step 4/6: Generating Auto-Provisioning Configuration Files..."

# 1. Datasource Config (InfluxDB v2 / Flux)
cat <<EOF | pct exec $CT_ID -- bash -c "cat > /root/tig-stack/grafana_provisioning/datasources/ds.yml"
apiVersion: 1
datasources:
  - name: InfluxDB
    type: influxdb
    access: proxy
    url: http://influxdb:8086
    isDefault: true
    jsonData:
      version: Flux
      organization: $ORG
      defaultBucket: $BUCKET
      tlsSkipVerify: true
    secureJsonData:
      token: $TOKEN
EOF

# 2. Dashboard Provider Config
cat <<EOF | pct exec $CT_ID -- bash -c "cat > /root/tig-stack/grafana_provisioning/dashboards/db.yml"
apiVersion: 1
providers:
  - name: 'Default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
EOF

# 3. GENERATE DASHBOARD JSON (Production Dashboard)
cat <<'EOF' | pct exec $CT_ID -- bash -c "cat > /root/tig-stack/grafana_dashboards/openwrt_prod.json"
{
  "annotations": { "list": [] },
  "editable": true,
  "gnetId": null,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Internet Traffic (WAN)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "bps" } },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"collectd\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r[\"_measurement\"] == \"interface_rx\" or r[\"_measurement\"] == \"interface_tx\")\n  |> filter(fn: (r) => r[\"type\"] == \"if_octets\")\n  |> filter(fn: (r) => r[\"_field\"] == \"value\")\n  |> derivative(unit: 1s, nonNegative: true)\n  |> map(fn: (r) => ({r with _value: r._value * 8.0}))\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)\n  |> yield(name: \"Traffic\")",
          "refId": "A"
        }
      ]
    },
    {
      "title": "CPU Usage",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "percent", "max": 100 } },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"collectd\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r[\"_measurement\"] == \"cpu_value\")\n  |> filter(fn: (r) => r[\"type\"] == \"cpu\")\n  |> filter(fn: (r) => r[\"type_instance\"] == \"user\" or r[\"type_instance\"] == \"system\")\n  |> derivative(unit: 1s, nonNegative: true)\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)\n  |> yield(name: \"CPU\")",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Memory Usage",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 8 },
      "fieldConfig": { "defaults": { "unit": "decbytes" } },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"collectd\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r[\"_measurement\"] == \"memory_value\")\n  |> filter(fn: (r) => r[\"type\"] == \"memory\")\n  |> filter(fn: (r) => r[\"type_instance\"] == \"used\" or r[\"type_instance\"] == \"free\")\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)\n  |> yield(name: \"RAM\")",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Active Connections",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 8 },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"collectd\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r[\"_measurement\"] == \"conntrack_value\")\n  |> filter(fn: (r) => r[\"_field\"] == \"value\")\n  |> aggregateWindow(every: v.windowPeriod, fn: max, createEmpty: false)\n  |> yield(name: \"Connections\")",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Ping Latency (8.8.8.8)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 8 },
      "fieldConfig": { "defaults": { "unit": "ms" } },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"collectd\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r[\"_measurement\"] == \"ping_value\")\n  |> filter(fn: (r) => r[\"type\"] == \"ping\")\n  |> filter(fn: (r) => r[\"_field\"] == \"value\")\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)\n  |> yield(name: \"Ping\")",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Router Temperature",
      "type": "gauge",
      "gridPos": { "h": 6, "w": 12, "x": 0, "y": 16 },
      "fieldConfig": { "defaults": { "unit": "celsius", "min": 0, "max": 100 } },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"collectd\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r[\"_measurement\"] == \"thermal_value\")\n  |> filter(fn: (r) => r[\"_field\"] == \"value\")\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)\n  |> yield(name: \"Temp\")",
          "refId": "A"
        }
      ]
    },
    {
      "title": "WiFi Signal Strength",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 12, "x": 12, "y": 16 },
      "fieldConfig": { "defaults": { "unit": "dBm" } },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "InfluxDB" },
          "query": "from(bucket: \"collectd\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r[\"_measurement\"] == \"iwinfo_value\")\n  |> filter(fn: (r) => r[\"type\"] == \"signal_power\")\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)\n  |> yield(name: \"WiFi\")",
          "refId": "A"
        }
      ]
    }
  ],
  "refresh": "5s",
  "schemaVersion": 30,
  "style": "dark",
  "timezone": "browser",
  "title": "OpenWrt Production Dashboard",
  "uid": "openwrt_prod"
}
EOF

# 4. Telegraf Config (Split Mode enabled for compatibility)
cat <<EOF | pct exec $CT_ID -- bash -c "cat > /root/tig-stack/telegraf.conf"
[agent]
  interval = "30s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  hostname = "$CT_HOSTNAME"

[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "$TOKEN"
  organization = "$ORG"
  bucket = "$BUCKET"

[[inputs.socket_listener]]
  service_address = "udp://:25826"
  data_format = "collectd"
  collectd_typesdb = ["/usr/share/collectd/types.db"]
  collectd_parse_multivalue = "split" 
EOF

log_info "Step 5/6: Generating Docker Compose Stack..."
cat <<EOF | pct exec $CT_ID -- bash -c "cat > /root/tig-stack/docker-compose.yml"
services:
  influxdb:
    image: influxdb:2.8.0-alpine
    container_name: influxdb
    restart: always
    ports:
      - "8086:8086"
    volumes:
      - ./influxdb_data:/var/lib/influxdb2
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME=admin
      - DOCKER_INFLUXDB_INIT_PASSWORD=telkom123
      - DOCKER_INFLUXDB_INIT_ORG=$ORG
      - DOCKER_INFLUXDB_INIT_BUCKET=$BUCKET
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=$TOKEN

  telegraf:
    image: telegraf:latest
    container_name: telegraf
    restart: always
    ports:
      - "25826:25826/udp"
    volumes:
      - ./telegraf.conf:/etc/telegraf/telegraf.conf:ro
      - ./types.db:/usr/share/collectd/types.db:ro
    depends_on:
      - influxdb

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: always
    ports:
      - "3000:3000"
    user: "472"
    volumes:
      - ./grafana_data:/var/lib/grafana
      - ./grafana_provisioning:/etc/grafana/provisioning
      - ./grafana_dashboards:/var/lib/grafana/dashboards
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=telkom123
    depends_on:
      - influxdb
EOF

log_info "Step 6/6: Launching Services..."
pct exec $CT_ID -- bash -c "sleep 10 && docker exec influxdb influx bucket update --name $BUCKET --retention 24h --org $ORG" 
pct exec $CT_ID -- bash -c "cd /root/tig-stack && docker compose up -d"

echo "==================================================="
echo "✅ DEPLOYMENT SUCCESSFUL"
echo "---------------------------------------------------"
echo "   Access Details:"
echo "   1. Grafana URL : http://100.0.0.111:3000"
echo "   2. Credentials : admin / telkom123"
echo "   3. Dashboard   : 'OpenWrt Production Dashboard'"
echo "==================================================="