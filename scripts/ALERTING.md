# Alerting and Notifications System

The Goose alerting system provides automated notifications for script failures, errors, and performance issues.

## Overview

The alerting system integrates with the structured logging infrastructure to automatically detect and notify about:
- Script failures (non-zero exit codes)
- High error counts
- Performance degradation
- Repeated failures

## Quick Start

### 1. Configure Alerts

Copy the example configuration file:

```bash
cp scripts/alert-config.json.example scripts/alert-config.json
```

Edit `alert-config.json` to enable your preferred alert channels (email, Slack, webhook, PagerDuty).

### 2. Automatic Alerts

Scripts using `logging-utils.sh` automatically trigger alerts on failures. No additional configuration needed.

### 3. Monitor for Alerts

Run the monitoring script to watch for alerts:

```bash
# Run once
RUN_ONCE=true ./scripts/monitor-alerts.sh

# Run continuously
./scripts/monitor-alerts.sh
```

## Components

### alerting-utils.sh

Core alerting functions that can be sourced by scripts:

- `send_alert()` - Send alert to all configured channels
- `check_script_failure()` - Check for script failures
- `check_error_count()` - Check for high error counts
- `check_performance_degradation()` - Check for slow executions
- `check_repeated_failures()` - Check for repeated failures
- `analyze_metrics_and_alert()` - Analyze metrics and trigger alerts

### monitor-alerts.sh

Monitoring script that watches log and metrics files for issues:

- Scans metrics files for failures and anomalies
- Monitors log files for errors
- Tracks repeated failures across script executions
- Cleans up old log files

### alert-config.json

Configuration file for alert thresholds and channels:

```json
{
  "thresholds": {
    "error_count": 1,
    "failure": 1,
    "duration_seconds": 3600,
    "repeated_failures": 3,
    "error_rate": 0.1
  },
  "channels": {
    "email": { "enabled": false, "to": "team@example.com" },
    "slack": { "enabled": false, "webhook_url": "..." },
    "webhook": { "enabled": false, "url": "..." },
    "pagerduty": { "enabled": false, "integration_key": "..." }
  }
}
```

## Alert Types

### Script Failure

**Trigger**: Script exits with non-zero exit code  
**Severity**: CRITICAL or HIGH  
**Automatic**: Yes (integrated into logging-utils.sh)

### High Error Count

**Trigger**: Error count exceeds threshold  
**Severity**: HIGH or CRITICAL  
**Automatic**: Yes (via monitor-alerts.sh or analyze_metrics_and_alert)

### Performance Degradation

**Trigger**: Script duration exceeds threshold  
**Severity**: MEDIUM  
**Automatic**: Yes (via analyze_metrics_and_alert)

### Repeated Failures

**Trigger**: Same script fails multiple times  
**Severity**: CRITICAL  
**Automatic**: Yes (via monitor-alerts.sh)

## Alert Channels

### Email

Requires `mail` or `sendmail` command:

```json
{
  "channels": {
    "email": {
      "enabled": true,
      "to": "team@example.com"
    }
  }
}
```

### Slack

Requires Slack webhook URL:

```json
{
  "channels": {
    "slack": {
      "enabled": true,
      "webhook_url": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
    }
  }
}
```

### Generic Webhook

Sends JSON payload to any HTTP endpoint:

```json
{
  "channels": {
    "webhook": {
      "enabled": true,
      "url": "https://your-webhook-endpoint.com/alerts"
    }
  }
}
```

### PagerDuty

Requires PagerDuty integration key:

```json
{
  "channels": {
    "pagerduty": {
      "enabled": true,
      "integration_key": "your-pagerduty-integration-key"
    }
  }
}
```

## Alert Deduplication

Alerts are automatically deduplicated to prevent alert fatigue. By default, the same alert won't be sent again within 5 minutes (300 seconds).

## Integration

### With logging-utils.sh

The alerting system is automatically integrated with `logging-utils.sh`. Scripts that source `logging-utils.sh` will automatically:

1. Check for failures on exit
2. Analyze metrics and trigger alerts if needed
3. Send alerts to configured channels

### Manual Integration

To use alerting in your own scripts:

```bash
source "$SCRIPT_DIR/alerting-utils.sh"

# Check for failure
check_script_failure "$?"

# Check for high error count
check_error_count "$LOG_FILE" "$ERROR_COUNT"

# Check for performance issues
check_performance_degradation "$DURATION"

# Send custom alert
send_alert "$SEVERITY_HIGH" "custom_alert" "Custom alert message" '{"key": "value"}'
```

## Monitoring

### Continuous Monitoring

Run the monitor script as a daemon:

```bash
nohup ./scripts/monitor-alerts.sh > /tmp/monitor.log 2>&1 &
```

### Cron Job

Add to crontab for periodic checks:

```bash
# Check every 5 minutes
*/5 * * * * /path/to/goose/scripts/monitor-alerts.sh RUN_ONCE=true
```

### One-Time Check

Run monitor once:

```bash
RUN_ONCE=true ./scripts/monitor-alerts.sh
```

## Configuration

### Environment Variables

- `ALERT_CONFIG_FILE` - Path to alert configuration file (default: `scripts/alert-config.json`)
- `ALERT_DEDUP_FILE` - Path to deduplication tracking file (default: `/tmp/goose-alerts-dedup.json`)
- `ALERT_LOG_FILE` - Path to alert log file (default: `/tmp/goose-alerts/alert-log.jsonl`)
- `LOG_DIR` - Directory containing log files (default: `/tmp/goose-logs`)
- `MONITOR_INTERVAL` - Monitoring interval in seconds (default: 60)
- `RETENTION_DAYS` - Log retention period in days (default: 30)

### Thresholds

Adjust thresholds in `alert-config.json`:

- `error_count` - Number of errors before alerting (default: 1)
- `failure` - Number of failures before alerting (default: 1)
- `duration_seconds` - Maximum duration before alerting (default: 3600)
- `repeated_failures` - Number of repeated failures before alerting (default: 3)
- `error_rate` - Error rate threshold (default: 0.1 = 10%)

## Troubleshooting

### Alerts Not Being Sent

1. Check alert configuration: `cat scripts/alert-config.json | jq '.channels'`
2. Verify at least one channel is enabled
3. Check alert log: `tail -f /tmp/goose-alerts/alert-log.jsonl | jq '.'`
4. Verify network connectivity for webhook-based channels

### Too Many Alerts

1. Increase thresholds in `alert-config.json`
2. Adjust deduplication window
3. Review and fix underlying issues causing alerts

### Missing Alerts

1. Check thresholds - may be too high
2. Verify alert channels are enabled
3. Check alert log for errors
4. Ensure scripts are using `logging-utils.sh`

## Runbook

See [ALERT_RUNBOOK.md](./ALERT_RUNBOOK.md) for detailed runbooks on:
- Investigating each alert type
- Common causes and resolutions
- Best practices
- Troubleshooting guide

## Examples

### Example: Custom Alert in Script

```bash
#!/bin/bash
source "$SCRIPT_DIR/logging-utils.sh"
source "$SCRIPT_DIR/alerting-utils.sh"

# Your script logic here
if [[ some_condition ]]; then
    send_alert "$SEVERITY_HIGH" "custom_issue" \
        "Something went wrong" \
        '{"condition": "failed", "details": "..."}'
fi
```

### Example: Check Metrics and Alert

```bash
#!/bin/bash
source "$SCRIPT_DIR/logging-utils.sh"
source "$SCRIPT_DIR/alerting-utils.sh"

# Run your script
your_script.sh

# Analyze metrics and alert if needed
if [[ -f "$METRICS_FILE" ]]; then
    analyze_metrics_and_alert "$METRICS_FILE"
fi
```

## Related Documentation

- [LOGGING_IMPROVEMENTS.md](./LOGGING_IMPROVEMENTS.md) - Structured logging infrastructure
- [ALERT_RUNBOOK.md](./ALERT_RUNBOOK.md) - Detailed runbooks for alerts
- [README.md](./README.md) - Script documentation

