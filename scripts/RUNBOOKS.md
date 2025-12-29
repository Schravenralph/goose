# Monitoring Operations Runbooks

This document provides operational runbooks for managing Goose monitoring tool integrations in production.

## Table of Contents

1. [Service Management](#service-management)
2. [Troubleshooting](#troubleshooting)
3. [Performance Tuning](#performance-tuning)
4. [Disaster Recovery](#disaster-recovery)
5. [Common Operations](#common-operations)

## Service Management

### Prometheus Exporter

#### Start Service
```bash
sudo systemctl start goose-prometheus-exporter
sudo systemctl status goose-prometheus-exporter
```

#### Stop Service
```bash
sudo systemctl stop goose-prometheus-exporter
```

#### Restart Service
```bash
sudo systemctl restart goose-prometheus-exporter
```

#### View Logs
```bash
# Recent logs
sudo journalctl -u goose-prometheus-exporter -n 50

# Follow logs
sudo journalctl -u goose-prometheus-exporter -f

# Logs since boot
sudo journalctl -u goose-prometheus-exporter -b
```

#### Check Service Health
```bash
# Check if service is running
systemctl is-active goose-prometheus-exporter

# Check if metrics endpoint is responding
curl http://localhost:9090/metrics

# Check if Prometheus is scraping
curl http://localhost:9090/api/v1/query?query=up{job="goose-metrics"}
```

### Datadog Forwarder

#### Start Service
```bash
sudo systemctl start goose-datadog-forwarder
sudo systemctl status goose-datadog-forwarder
```

#### Stop Service
```bash
sudo systemctl stop goose-datadog-forwarder
```

#### Restart Service
```bash
sudo systemctl restart goose-datadog-forwarder
```

#### View Logs
```bash
# Recent logs
sudo journalctl -u goose-datadog-forwarder -n 50

# Follow logs
sudo journalctl -u goose-datadog-forwarder -f

# Logs with errors only
sudo journalctl -u goose-datadog-forwarder | grep -i error
```

#### Check Service Health
```bash
# Check if service is running
systemctl is-active goose-datadog-forwarder

# Check API key configuration
sudo cat /etc/goose-monitoring/datadog.env | grep DD_API_KEY

# Verify in Datadog UI
# Go to: Logs → Explorer → Filter: service:goose-scripts
# Go to: Metrics → Explorer → Search: goose.*
```

### Filebeat

#### Start Service
```bash
sudo systemctl start filebeat
sudo systemctl status filebeat
```

#### Stop Service
```bash
sudo systemctl stop filebeat
```

#### Restart Service
```bash
sudo systemctl restart filebeat
```

#### View Logs
```bash
# Filebeat logs
sudo tail -f /var/log/filebeat/filebeat

# Check Filebeat status
sudo filebeat status
```

#### Test Configuration
```bash
# Test config
sudo filebeat test config

# Test output
sudo filebeat test output
```

## Troubleshooting

### No Metrics Appearing in Prometheus

**Symptoms:**
- Prometheus exporter is running
- No metrics visible in Prometheus UI
- Query returns no results

**Steps:**
1. Check if exporter is responding:
   ```bash
   curl http://localhost:9090/metrics
   ```

2. Check if metrics files exist:
   ```bash
   ls -la /tmp/goose-logs/*-metrics-*.json
   ```

3. Check Prometheus scrape configuration:
   ```bash
   grep -A 5 "goose-metrics" /etc/prometheus/prometheus.yml
   ```

4. Check Prometheus targets:
   ```bash
   curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="goose-metrics")'
   ```

5. Restart Prometheus if needed:
   ```bash
   sudo systemctl reload prometheus
   ```

### No Logs in Elasticsearch

**Symptoms:**
- Filebeat is running
- No logs in Elasticsearch
- Kibana shows no data

**Steps:**
1. Check Filebeat status:
   ```bash
   sudo filebeat status
   ```

2. Check if log files exist:
   ```bash
   ls -la /tmp/goose-logs/*.jsonl
   ```

3. Check Filebeat configuration:
   ```bash
   sudo filebeat test config
   ```

4. Check Elasticsearch connection:
   ```bash
   sudo filebeat test output
   ```

5. Check Elasticsearch indices:
   ```bash
   curl http://localhost:9200/_cat/indices/goose-logs-*?v
   ```

6. Check Filebeat logs for errors:
   ```bash
   sudo tail -f /var/log/filebeat/filebeat | grep -i error
   ```

### Datadog Forwarder Not Sending Data

**Symptoms:**
- Forwarder service is running
- No logs/metrics in Datadog
- No errors in service logs

**Steps:**
1. Check API key:
   ```bash
   sudo cat /etc/goose-monitoring/datadog.env | grep DD_API_KEY
   ```

2. Test API key manually:
   ```bash
   export DD_API_KEY=$(sudo grep DD_API_KEY /etc/goose-monitoring/datadog.env | cut -d'=' -f2)
   curl -X POST "https://http-intake.logs.datadoghq.com/v1/input/${DD_API_KEY}" \
     -H "Content-Type: application/json" \
     -d '{"message":"test"}'
   ```

3. Check service logs:
   ```bash
   sudo journalctl -u goose-datadog-forwarder -n 50 | grep -i error
   ```

4. Verify log/metrics files exist:
   ```bash
   ls -la /tmp/goose-logs/
   ```

5. Run forwarder manually to see output:
   ```bash
   sudo -u goose DD_API_KEY=$(sudo grep DD_API_KEY /etc/goose-monitoring/datadog.env | cut -d'=' -f2) \
     /home/goose/goose/scripts/datadog-forwarder.sh --interval 10
   ```

### High CPU/Memory Usage

**Symptoms:**
- Service consuming excessive resources
- System performance degradation

**Steps:**
1. Identify resource usage:
   ```bash
   top -p $(pgrep -f prometheus-exporter)
   top -p $(pgrep -f datadog-forwarder)
   ```

2. Check process count:
   ```bash
   ps aux | grep -E "prometheus-exporter|datadog-forwarder" | wc -l
   ```

3. Reduce scrape/forward intervals:
   - Prometheus exporter: Increase `PROMETHEUS_SCRAPE_INTERVAL`
   - Datadog forwarder: Increase `--interval` value

4. Reduce batch sizes:
   - Datadog forwarder: Reduce `BATCH_SIZE` in script

5. Restart service:
   ```bash
   sudo systemctl restart goose-prometheus-exporter
   sudo systemctl restart goose-datadog-forwarder
   ```

### Disk Space Issues

**Symptoms:**
- Disk space warnings
- Services failing to write logs

**Steps:**
1. Check disk usage:
   ```bash
   df -h /tmp/goose-logs/
   du -sh /tmp/goose-logs/
   ```

2. Count log/metrics files:
   ```bash
   find /tmp/goose-logs -name "*.jsonl" | wc -l
   find /tmp/goose-logs -name "*-metrics-*.json" | wc -l
   ```

3. Set up log rotation (if not already):
   ```bash
   ./scripts/rotate-logs.sh
   ```

4. Clean old files manually:
   ```bash
   # Remove files older than 7 days
   find /tmp/goose-logs -name "*.jsonl" -mtime +7 -delete
   find /tmp/goose-logs -name "*-metrics-*.json" -mtime +7 -delete
   ```

5. Check if rotation is working:
   ```bash
   systemctl status logrotate
   ls -la /tmp/goose-logs/
   ```

## Performance Tuning

### Prometheus Exporter

**Optimize scrape interval:**
```bash
# Edit service file
sudo nano /etc/systemd/system/goose-prometheus-exporter.service

# Add or modify:
Environment="PROMETHEUS_SCRAPE_INTERVAL=60"

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart goose-prometheus-exporter
```

**Limit metrics file age:**
- Modify script to only process recent files
- Default: 7 days (`-mtime -7`)

### Datadog Forwarder

**Increase forwarding interval:**
```bash
# Edit service file
sudo nano /etc/systemd/system/goose-datadog-forwarder.service

# Modify ExecStart:
ExecStart=/home/goose/goose/scripts/datadog-forwarder.sh --interval 120

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart goose-datadog-forwarder
```

**Reduce batch size:**
- Edit `datadog-forwarder.sh`
- Reduce `BATCH_SIZE` variable (default: 100)

### Filebeat

**Optimize file scanning:**
```bash
# Edit Filebeat config
sudo nano /etc/filebeat/filebeat.yml

# Add under filebeat.inputs:
  scan_frequency: 30s
  harvester_buffer_size: 16384
```

## Disaster Recovery

### Service Recovery

If a service fails:

1. **Check service status:**
   ```bash
   sudo systemctl status goose-prometheus-exporter
   sudo systemctl status goose-datadog-forwarder
   ```

2. **Check logs for errors:**
   ```bash
   sudo journalctl -u goose-prometheus-exporter -n 100
   sudo journalctl -u goose-datadog-forwarder -n 100
   ```

3. **Restart service:**
   ```bash
   sudo systemctl restart goose-prometheus-exporter
   sudo systemctl restart goose-datadog-forwarder
   ```

4. **Verify service is running:**
   ```bash
   sudo systemctl status goose-prometheus-exporter
   sudo systemctl status goose-datadog-forwarder
   ```

5. **Run validation script:**
   ```bash
   ./scripts/validate-monitoring-deployment.sh
   ```

### Configuration Recovery

If configuration is lost:

1. **Restore from backup:**
   ```bash
   # Service files
   sudo cp /backup/goose-prometheus-exporter.service /etc/systemd/system/
   sudo cp /backup/goose-datadog-forwarder.service /etc/systemd/system/
   
   # Environment files
   sudo cp /backup/datadog.env /etc/goose-monitoring/
   
   # Reload systemd
   sudo systemctl daemon-reload
   ```

2. **Restart services:**
   ```bash
   sudo systemctl restart goose-prometheus-exporter
   sudo systemctl restart goose-datadog-forwarder
   ```

### Data Recovery

If log/metrics data is lost:

1. **Check backup locations:**
   ```bash
   ls -la /backup/goose-logs/
   ```

2. **Restore from backup:**
   ```bash
   cp -r /backup/goose-logs/* /tmp/goose-logs/
   ```

3. **Verify data:**
   ```bash
   ls -la /tmp/goose-logs/
   ```

## Common Operations

### Update Configuration

1. **Edit configuration files:**
   ```bash
   sudo nano /etc/goose-monitoring/datadog.env
   sudo nano /etc/systemd/system/goose-prometheus-exporter.service
   ```

2. **Reload systemd:**
   ```bash
   sudo systemctl daemon-reload
   ```

3. **Restart services:**
   ```bash
   sudo systemctl restart goose-prometheus-exporter
   sudo systemctl restart goose-datadog-forwarder
   ```

### Update Scripts

1. **Pull latest changes:**
   ```bash
   cd /home/goose/goose
   git pull
   ```

2. **Restart services:**
   ```bash
   sudo systemctl restart goose-prometheus-exporter
   sudo systemctl restart goose-datadog-forwarder
   ```

3. **Verify deployment:**
   ```bash
   ./scripts/validate-monitoring-deployment.sh
   ```

### Monitor Service Health

**Create monitoring dashboard:**
- Use Grafana to monitor service metrics
- Set up alerts for service failures
- Monitor resource usage

**Regular checks:**
```bash
# Daily health check
./scripts/validate-monitoring-deployment.sh

# Check service status
systemctl status goose-prometheus-exporter
systemctl status goose-datadog-forwarder

# Check disk usage
df -h /tmp/goose-logs/
```

### Rotate Logs

**Manual rotation:**
```bash
./scripts/rotate-logs.sh
```

**Automatic rotation:**
- Configure logrotate (see `scripts/rotate-logs.sh`)
- Set up cron job for regular rotation

## Support Contacts

- **Documentation**: `PRODUCTION_DEPLOYMENT.md`
- **Integration Guide**: `MONITORING_INTEGRATION.md`
- **Validation Script**: `validate-monitoring-deployment.sh`

