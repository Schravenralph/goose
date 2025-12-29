# Monitoring Tool Integration Guide

This guide explains how to integrate Goose script logs and metrics with popular monitoring and observability tools: Prometheus, Grafana, ELK Stack, and Datadog.

## Overview

Goose scripts generate structured JSON logs (`.jsonl`) and metrics (`.json`) that can be integrated with various monitoring tools. This document provides step-by-step instructions for each integration.

## Prerequisites

- Goose scripts with structured logging enabled (using `logging-utils.sh`)
- Logs directory: `/tmp/goose-logs` (or custom `LOG_DIR`)
- Metrics directory: `/tmp/goose-logs` (or custom `METRICS_DIR`)
- `jq` installed for JSON processing
- Access to the monitoring tool you want to integrate with

## Prometheus Integration

Prometheus is a time-series database and monitoring system. This integration allows Prometheus to scrape Goose metrics.

### Setup

1. **Start the Prometheus Exporter**:
   ```bash
   ./scripts/prometheus-exporter.sh --port 9090 --metrics-dir /tmp/goose-logs
   ```

   Or use environment variables:
   ```bash
   export PROMETHEUS_EXPORTER_PORT=9090
   export PROMETHEUS_METRICS_DIR=/tmp/goose-logs
   ./scripts/prometheus-exporter.sh
   ```

2. **Verify the exporter is running**:
   ```bash
   curl http://localhost:9090/metrics
   ```

   You should see Prometheus-formatted metrics.

3. **Configure Prometheus**:
   Copy `prometheus.yml.example` to your Prometheus configuration directory:
   ```bash
   cp scripts/prometheus.yml.example /etc/prometheus/prometheus.yml
   # Edit as needed
   ```

   Or add to your existing `prometheus.yml`:
   ```yaml
   scrape_configs:
     - job_name: 'goose-metrics'
       static_configs:
         - targets: ['localhost:9090']
   ```

4. **Start Prometheus**:
   ```bash
   prometheus --config.file=/etc/prometheus/prometheus.yml
   ```

5. **Access Prometheus UI**:
   Open http://localhost:9090 in your browser and query metrics like:
   - `goose_duration{script="clippy-lint"}`
   - `goose_exit_code{script="clippy-lint"}`
   - `goose_clippy_warnings{script="clippy-lint"}`

### Metrics Available

All metrics are prefixed with `goose_` and include a `script` label:
- `goose_duration` - Script execution duration in seconds
- `goose_exit_code` - Script exit code (0 = success)
- `goose_clippy_warnings` - Number of clippy warnings
- `goose_clippy_errors` - Number of clippy errors
- `goose_metrics_files_total` - Total number of metrics files

### Troubleshooting

- **Port already in use**: Change the port with `--port` option
- **No metrics**: Ensure metrics files exist in the metrics directory
- **Connection refused**: Check that the exporter is running and accessible

## Grafana Integration

Grafana is a visualization and analytics platform. Use it to create dashboards for Goose metrics.

### Setup

1. **Install Grafana** (if not already installed):
   ```bash
   # Ubuntu/Debian
   sudo apt-get install grafana
   
   # macOS
   brew install grafana
   ```

2. **Start Grafana**:
   ```bash
   sudo systemctl start grafana-server  # Linux
   # or
   brew services start grafana  # macOS
   ```

3. **Add Prometheus as Data Source**:
   - Open Grafana UI: http://localhost:3000
   - Go to Configuration → Data Sources → Add data source
   - Select Prometheus
   - URL: `http://localhost:9090` (Prometheus server, not the exporter)
   - Click "Save & Test"

4. **Import Dashboard**:
   - Go to Dashboards → Import
   - Upload `scripts/grafana-dashboard-goose.json`
   - Select the Prometheus data source
   - Click "Import"

### Custom Dashboards

You can create custom dashboards using Prometheus queries:
- **Success Rate**: `sum(goose_exit_code == 0) / count(goose_exit_code) * 100`
- **Average Duration**: `avg(goose_duration)`
- **Error Rate**: `sum(goose_clippy_errors) / count(goose_exit_code)`

### Troubleshooting

- **No data**: Ensure Prometheus is scraping metrics and Grafana is connected to Prometheus
- **Dashboard not loading**: Check that the Prometheus data source is configured correctly

## ELK Stack Integration

The ELK Stack (Elasticsearch, Logstash, Kibana) provides log aggregation and analysis.

### Option 1: Using Filebeat (Recommended)

Filebeat is lightweight and easy to configure.

1. **Install Filebeat**:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install filebeat
   
   # macOS
   brew install filebeat
   ```

2. **Configure Filebeat**:
   ```bash
   sudo cp scripts/filebeat-goose.yml.example /etc/filebeat/filebeat.yml
   sudo nano /etc/filebeat/filebeat.yml  # Edit paths as needed
   ```

3. **Start Filebeat**:
   ```bash
   sudo systemctl start filebeat  # Linux
   # or
   filebeat -e -c /etc/filebeat/filebeat.yml  # macOS
   ```

4. **Verify in Elasticsearch**:
   ```bash
   curl http://localhost:9200/goose-logs-*/_search?pretty
   ```

5. **View in Kibana**:
   - Open Kibana: http://localhost:5601
   - Go to Management → Index Patterns
   - Create index pattern: `goose-logs-*`
   - Go to Discover to view logs

### Option 2: Using Logstash

Logstash provides more processing capabilities.

1. **Install Logstash**:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install logstash
   
   # macOS
   brew install logstash
   ```

2. **Configure Logstash**:
   ```bash
   sudo cp scripts/logstash-goose.conf.example /etc/logstash/conf.d/goose.conf
   sudo nano /etc/logstash/conf.d/goose.conf  # Edit paths as needed
   ```

3. **Start Logstash**:
   ```bash
   sudo systemctl start logstash  # Linux
   # or
   logstash -f /etc/logstash/conf.d/goose.conf  # macOS
   ```

4. **Verify in Elasticsearch and Kibana** (same as Filebeat)

### Log Fields

Logs include the following fields:
- `timestamp` - ISO 8601 timestamp
- `level` - Log level (DEBUG, INFO, WARN, ERROR, FATAL)
- `trace_id` - Unique trace ID for correlation
- `span_id` - Span ID for operation tracking
- `script` - Script name
- `message` - Log message
- `hostname` - Hostname
- `user` - User who ran the script
- `pid` - Process ID

### Troubleshooting

- **Logs not appearing**: Check Filebeat/Logstash logs and ensure paths are correct
- **Elasticsearch connection errors**: Verify Elasticsearch is running and accessible
- **Index not found**: Create the index pattern in Kibana

## Datadog Integration

Datadog is a cloud-based monitoring and analytics platform.

### Setup

1. **Get Datadog API Key**:
   - Log in to Datadog
   - Go to Organization Settings → API Keys
   - Create a new API key or use an existing one

2. **Start the Datadog Forwarder**:
   ```bash
   export DD_API_KEY="your-api-key-here"
   ./scripts/datadog-forwarder.sh
   ```

   Or with options:
   ```bash
   ./scripts/datadog-forwarder.sh \
     --api-key "your-api-key" \
     --log-dir /tmp/goose-logs \
     --metrics-dir /tmp/goose-logs \
     --interval 60
   ```

3. **Verify in Datadog**:
   - Go to Logs → Explorer
   - Filter by `service:goose-scripts`
   - Go to Metrics → Explorer
   - Search for `goose.*` metrics

### Configuration Options

- `--logs-only` - Forward only logs
- `--metrics-only` - Forward only metrics
- `--api-key KEY` - Datadog API key
- `--site SITE` - Datadog site (default: datadoghq.com)
- `--log-dir DIR` - Log directory
- `--metrics-dir DIR` - Metrics directory
- `--interval SECONDS` - Forwarding interval (default: 60)

### Environment Variables

- `DD_API_KEY` - Datadog API key (required)
- `DD_SITE` - Datadog site (default: datadoghq.com)
- `LOG_DIR` - Log directory
- `METRICS_DIR` - Metrics directory

### Log Attributes

Logs are enriched with:
- `ddsource: goose`
- `service: goose-scripts`
- `host: <hostname>`
- `env: production`

### Metrics

Metrics are sent with:
- Metric name: `goose.<metric_name>`
- Tags: `script:<script_name>`
- Type: `gauge`

### Troubleshooting

- **API key errors**: Verify your API key is correct and has proper permissions
- **No logs/metrics**: Check that the forwarder is running and files exist
- **Rate limiting**: Increase the `--interval` to reduce API calls

## Running Multiple Integrations

You can run multiple integrations simultaneously:

```bash
# Terminal 1: Prometheus exporter
./scripts/prometheus-exporter.sh --port 9090

# Terminal 2: Datadog forwarder
export DD_API_KEY="your-key"
./scripts/datadog-forwarder.sh

# Terminal 3: Filebeat (as service)
sudo systemctl start filebeat
```

## Best Practices

1. **Log Rotation**: Use `rotate-logs.sh` to prevent disk space issues
2. **Retention**: Set up retention policies for logs and metrics
3. **Monitoring**: Monitor the monitoring tools themselves
4. **Alerts**: Set up alerts for critical errors and failures
5. **Performance**: Adjust scrape/forward intervals based on volume

## Troubleshooting Common Issues

### No Metrics/Logs Appearing

1. Check that scripts are generating logs/metrics:
   ```bash
   ls -la /tmp/goose-logs/
   ```

2. Verify file permissions:
   ```bash
   ls -l /tmp/goose-logs/*.jsonl
   ```

3. Check script execution:
   ```bash
   ./scripts/clippy-lint.sh
   ```

### Integration Not Working

1. Check service status:
   ```bash
   # Prometheus exporter
   curl http://localhost:9090/metrics
   
   # Elasticsearch
   curl http://localhost:9200
   
   # Datadog (check forwarder logs)
   ```

2. Verify configuration files:
   - Check paths in configuration files
   - Verify API keys and endpoints
   - Check network connectivity

3. Review logs:
   - Check integration tool logs
   - Check system logs for errors

## Additional Resources

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [ELK Stack Documentation](https://www.elastic.co/guide/)
- [Datadog Documentation](https://docs.datadoghq.com/)
- [Goose Logging Improvements](./LOGGING_IMPROVEMENTS.md)

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review integration tool documentation
3. Check Goose script logs for errors
4. Verify configuration files are correct

