# Production Deployment Guide for Monitoring Tool Integrations

This guide provides step-by-step instructions for deploying Goose monitoring tool integrations in a production environment.

## Overview

This deployment guide covers:
- Prometheus exporter deployment
- Grafana dashboard configuration
- ELK Stack log ingestion
- Datadog log/metric forwarding
- Automated data collection setup
- Alerting configuration
- Validation and troubleshooting

## Prerequisites

Before starting, ensure you have:
- Access to the production environment
- Root or sudo access for service installation
- Network access to monitoring tool endpoints
- Appropriate credentials/API keys for each tool
- Understanding of which monitoring tools are available in your environment

## Step 1: Identify Available Monitoring Tools

First, identify which monitoring tools are available in your environment:

```bash
# Check for Prometheus
curl -s http://localhost:9090/api/v1/status/config 2>/dev/null && echo "Prometheus available"

# Check for Grafana
curl -s http://localhost:3000/api/health 2>/dev/null && echo "Grafana available"

# Check for Elasticsearch
curl -s http://localhost:9200 2>/dev/null && echo "Elasticsearch available"

# Check for Datadog agent
systemctl status datadog-agent 2>/dev/null || echo "Datadog agent status unknown"
```

Document which tools are available and their endpoints.

## Step 2: Deploy Prometheus Exporter (if Prometheus available)

### 2.1 Install as Systemd Service

1. **Copy service file**:
   ```bash
   sudo cp scripts/goose-prometheus-exporter.service /etc/systemd/system/
   ```

2. **Edit configuration** (if needed):
   ```bash
   sudo nano /etc/systemd/system/goose-prometheus-exporter.service
   ```

3. **Reload systemd and start service**:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable goose-prometheus-exporter
   sudo systemctl start goose-prometheus-exporter
   ```

4. **Verify service is running**:
   ```bash
   sudo systemctl status goose-prometheus-exporter
   curl http://localhost:9090/metrics
   ```

### 2.2 Configure Prometheus to Scrape

1. **Add scrape config to Prometheus** (`/etc/prometheus/prometheus.yml`):
   ```yaml
   scrape_configs:
     - job_name: 'goose-metrics'
       static_configs:
         - targets: ['localhost:9090']
       scrape_interval: 30s
       scrape_timeout: 10s
   ```

2. **Reload Prometheus**:
   ```bash
   sudo systemctl reload prometheus
   # or
   curl -X POST http://localhost:9090/-/reload
   ```

3. **Verify in Prometheus UI**:
   - Open http://localhost:9090
   - Query: `goose_execution_duration_seconds`

## Step 3: Configure Grafana Dashboards (if Grafana available)

### 3.1 Add Prometheus Data Source

1. **Open Grafana UI**: http://localhost:3000
2. **Go to**: Configuration → Data Sources → Add data source
3. **Select**: Prometheus
4. **URL**: `http://localhost:9090` (Prometheus server, not exporter)
5. **Click**: Save & Test

### 3.2 Import Dashboard

1. **Go to**: Dashboards → Import
2. **Upload**: `scripts/grafana-dashboard-goose.json`
3. **Select**: Prometheus data source
4. **Click**: Import

### 3.3 Verify Dashboard

- Check that metrics are appearing
- Verify panels are displaying data
- Test time range selection

## Step 4: Deploy ELK Stack Integration (if ELK available)

### Option A: Using Filebeat (Recommended)

1. **Install Filebeat** (if not installed):
   ```bash
   # Ubuntu/Debian
   sudo apt-get install filebeat
   
   # RHEL/CentOS
   sudo yum install filebeat
   ```

2. **Copy configuration**:
   ```bash
   sudo cp scripts/filebeat-goose.yml.example /etc/filebeat/filebeat.yml
   ```

3. **Edit configuration**:
   ```bash
   sudo nano /etc/filebeat/filebeat.yml
   ```
   Update:
   - Log paths
   - Elasticsearch host/port
   - Authentication credentials

4. **Test configuration**:
   ```bash
   sudo filebeat test config
   sudo filebeat test output
   ```

5. **Start and enable Filebeat**:
   ```bash
   sudo systemctl enable filebeat
   sudo systemctl start filebeat
   ```

6. **Verify in Elasticsearch**:
   ```bash
   curl http://localhost:9200/goose-logs-*/_search?pretty
   ```

7. **Create Kibana index pattern**:
   - Open Kibana: http://localhost:5601
   - Go to: Management → Index Patterns
   - Create pattern: `goose-logs-*`
   - Time field: `@timestamp`

### Option B: Using Logstash

1. **Install Logstash** (if not installed):
   ```bash
   # Ubuntu/Debian
   sudo apt-get install logstash
   ```

2. **Copy configuration**:
   ```bash
   sudo cp scripts/logstash-goose.conf.example /etc/logstash/conf.d/goose.conf
   ```

3. **Edit configuration**:
   ```bash
   sudo nano /etc/logstash/conf.d/goose.conf
   ```

4. **Test configuration**:
   ```bash
   sudo /usr/share/logstash/bin/logstash --config.test_and_exit --path.config /etc/logstash/conf.d/goose.conf
   ```

5. **Start Logstash**:
   ```bash
   sudo systemctl enable logstash
   sudo systemctl start logstash
   ```

## Step 5: Deploy Datadog Forwarder (if Datadog available)

### 5.1 Install as Systemd Service

1. **Get Datadog API Key**:
   - Log in to Datadog
   - Go to: Organization Settings → API Keys
   - Create or copy API key

2. **Create environment file**:
   ```bash
   sudo mkdir -p /etc/goose-monitoring
   sudo nano /etc/goose-monitoring/datadog.env
   ```
   Add:
   ```
   DD_API_KEY=your-api-key-here
   DD_SITE=datadoghq.com
   LOG_DIR=/tmp/goose-logs
   METRICS_DIR=/tmp/goose-logs
   ```

3. **Copy service file**:
   ```bash
   sudo cp scripts/goose-datadog-forwarder.service /etc/systemd/system/
   ```

4. **Edit service file** (if paths differ):
   ```bash
   sudo nano /etc/systemd/system/goose-datadog-forwarder.service
   ```

5. **Reload systemd and start service**:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable goose-datadog-forwarder
   sudo systemctl start goose-datadog-forwarder
   ```

6. **Verify service**:
   ```bash
   sudo systemctl status goose-datadog-forwarder
   sudo journalctl -u goose-datadog-forwarder -f
   ```

7. **Verify in Datadog**:
   - Go to: Logs → Explorer
   - Filter: `service:goose-scripts`
   - Go to: Metrics → Explorer
   - Search: `goose.*`

## Step 6: Set Up Automated Data Collection

### 6.1 Verify Script Logging

Ensure Goose scripts are generating logs and metrics:

```bash
# Run a test script
./scripts/clippy-lint.sh

# Verify logs/metrics are created
ls -la /tmp/goose-logs/
```

### 6.2 Configure Log Rotation (if not already done)

See `scripts/rotate-logs.sh` for log rotation setup.

### 6.3 Set Up Cron Jobs (if needed)

For scripts that don't run automatically, set up cron jobs:

```bash
# Edit crontab
crontab -e

# Example: Run clippy-lint daily at 2 AM
0 2 * * * /path/to/goose/scripts/clippy-lint.sh >> /tmp/goose-logs/cron.log 2>&1
```

## Step 7: Configure Alerting

### 7.1 Prometheus Alerting Rules

1. **Copy alerting rules**:
   ```bash
   sudo cp scripts/prometheus-alerts-goose.yml /etc/prometheus/rules/
   ```

2. **Update Prometheus config** (`/etc/prometheus/prometheus.yml`):
   ```yaml
   rule_files:
     - "/etc/prometheus/rules/prometheus-alerts-goose.yml"
   ```

3. **Reload Prometheus**:
   ```bash
   sudo systemctl reload prometheus
   ```

### 7.2 Grafana Alerts

1. **Open Grafana dashboard**
2. **Edit panel** → Alert tab
3. **Configure alert conditions**
4. **Set notification channels**

### 7.3 Datadog Monitors

1. **Go to**: Datadog → Monitors → New Monitor
2. **Select**: Metric Monitor
3. **Query**: `goose.exit_code > 0`
4. **Set conditions**: Alert when > 0
5. **Configure notifications**

## Step 8: Validate End-to-End Data Flow

Run the validation script:

```bash
./scripts/validate-monitoring-deployment.sh
```

This script checks:
- Services are running
- Metrics are being scraped
- Logs are being ingested
- Data is appearing in monitoring tools

## Step 9: Document Deployment

Document your deployment:
- Which tools are deployed
- Service endpoints
- Configuration locations
- API keys/credentials (securely)
- Custom configurations

## Step 10: Create Runbooks

See `scripts/RUNBOOKS.md` for operational runbooks covering:
- Service restart procedures
- Troubleshooting common issues
- Performance tuning
- Disaster recovery

## Troubleshooting

### Services Not Starting

1. **Check service status**:
   ```bash
   sudo systemctl status goose-prometheus-exporter
   sudo systemctl status goose-datadog-forwarder
   ```

2. **Check logs**:
   ```bash
   sudo journalctl -u goose-prometheus-exporter -n 50
   sudo journalctl -u goose-datadog-forwarder -n 50
   ```

3. **Verify permissions**:
   ```bash
   ls -la /tmp/goose-logs/
   ```

### No Data Appearing

1. **Verify scripts are generating logs/metrics**:
   ```bash
   ls -la /tmp/goose-logs/
   tail -f /tmp/goose-logs/*.jsonl
   ```

2. **Check service connectivity**:
   ```bash
   curl http://localhost:9090/metrics  # Prometheus exporter
   curl http://localhost:9200          # Elasticsearch
   ```

3. **Verify configuration**:
   - Check paths in service files
   - Verify API keys/credentials
   - Check network connectivity

### Performance Issues

1. **Adjust intervals**:
   - Increase scrape intervals
   - Increase forwarding intervals
   - Reduce batch sizes

2. **Monitor resource usage**:
   ```bash
   top -p $(pgrep -f prometheus-exporter)
   top -p $(pgrep -f datadog-forwarder)
   ```

3. **Check disk space**:
   ```bash
   df -h /tmp/goose-logs/
   ```

## Security Considerations

1. **API Keys**: Store securely, never commit to version control
2. **Network**: Use HTTPS for external endpoints
3. **Authentication**: Configure authentication for monitoring tools
4. **Permissions**: Use least privilege for service accounts
5. **Logs**: Don't log sensitive information

## Maintenance

### Regular Tasks

- Monitor disk usage for logs/metrics
- Review alerting rules
- Update configurations as needed
- Review and rotate API keys
- Test disaster recovery procedures

### Updates

When updating scripts:
1. Test in staging first
2. Backup configurations
3. Update service files if paths change
4. Restart services
5. Validate data flow

## Support

For issues:
1. Check troubleshooting section
2. Review service logs
3. Run validation script
4. Check monitoring tool documentation
5. Review Goose script logs

## Related Documentation

- `MONITORING_INTEGRATION.md` - Integration guide
- `RUNBOOKS.md` - Operational runbooks
- `LOGGING_IMPROVEMENTS.md` - Logging infrastructure

