# Log Rotation and Retention Policies

This document describes the log rotation and retention policies for Goose scripts and how to use the cleanup and archival system.

## Overview

The log cleanup and retention system manages disk space by:
- Removing old log files based on retention policies
- Archiving important logs (those containing errors or failures)
- Compressing archived logs to save space
- Supporting different retention periods for logs and metrics

## Retention Policies

### Default Retention Periods

- **Regular Logs**: 30 days
- **Archived Logs**: 365 days (1 year)
- **Metrics Files**: 90 days
- **Maximum Log Size**: 100 MB (warning threshold)

### Retention Strategy

1. **Regular Logs** (`.jsonl` files):
   - Logs older than the retention period are evaluated
   - Logs containing ERROR or FATAL level entries are archived
   - Logs without errors are deleted after the retention period

2. **Metrics Files** (`*-metrics-*.json` files):
   - Metrics files are kept longer than regular logs (90 days by default)
   - Metrics files indicating failures (exit_code != 0) are archived
   - Other metrics files are deleted after the retention period

3. **Archived Logs**:
   - Archived logs are kept for 1 year by default
   - Archives are compressed using gzip (if available)
   - Old archives are automatically cleaned up

## Usage

### Basic Usage

Run the cleanup script to remove old logs according to retention policies:

```bash
# Use default settings (30 days retention)
./scripts/cleanup-logs.sh

# Dry run to see what would be done
./scripts/cleanup-logs.sh --dry-run
```

### Custom Retention Periods

```bash
# Keep logs for 7 days, archives for 1 year
./scripts/cleanup-logs.sh --retention-days 7 --archive-retention-days 365

# Keep metrics for 180 days
./scripts/cleanup-logs.sh --metrics-retention-days 180

# Custom log and archive directories
./scripts/cleanup-logs.sh --log-dir /var/log/goose --archive-dir /var/log/goose/archive
```

### Environment Variables

You can configure the script using environment variables:

```bash
export LOG_DIR="/var/log/goose"
export ARCHIVE_DIR="/var/log/goose/archive"
export RETENTION_DAYS=30
export ARCHIVE_RETENTION_DAYS=365
export METRICS_RETENTION_DAYS=90
export MAX_LOG_SIZE_MB=100
export COMPRESS_ARCHIVES=true

./scripts/cleanup-logs.sh
```

### All Options

```bash
./scripts/cleanup-logs.sh \
  --log-dir /tmp/goose-logs \
  --archive-dir /tmp/goose-logs/archive \
  --retention-days 30 \
  --archive-retention-days 365 \
  --metrics-retention-days 90 \
  --max-log-size-mb 100 \
  --compress \
  --dry-run
```

## Automated Cleanup

### Cron Job Setup

To run cleanup automatically, add a cron job. For example, to run cleanup daily at 2 AM:

```bash
# Edit crontab
crontab -e

# Add this line:
0 2 * * * /path/to/goose/scripts/cleanup-logs.sh >> /tmp/goose-cleanup.log 2>&1
```

### Systemd Timer (Linux)

Create a systemd timer for more control:

**`/etc/systemd/system/goose-log-cleanup.service`:**
```ini
[Unit]
Description=Goose Log Cleanup
After=network.target

[Service]
Type=oneshot
ExecStart=/path/to/goose/scripts/cleanup-logs.sh
User=goose
Environment="LOG_DIR=/var/log/goose"
Environment="ARCHIVE_DIR=/var/log/goose/archive"
```

**`/etc/systemd/system/goose-log-cleanup.timer`:**
```ini
[Unit]
Description=Goose Log Cleanup Timer
Requires=goose-log-cleanup.service

[Timer]
OnCalendar=daily
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
sudo systemctl enable goose-log-cleanup.timer
sudo systemctl start goose-log-cleanup.timer
```

## What Gets Archived

Logs are archived if they contain:
- ERROR level log entries
- FATAL level log entries
- Metrics files with exit_code != 0

Archived logs are:
- Copied to the archive directory
- Compressed using gzip (if available)
- Kept for the archive retention period (1 year by default)

## File Naming

- **Log files**: `{script-name}-{timestamp}.jsonl`
- **Metrics files**: `{script-name}-metrics-{timestamp}.json`
- **Archived logs**: `{script-name}-{timestamp}.jsonl` (or `.jsonl.gz` if compressed)
- **Archived metrics**: `{script-name}-metrics-{timestamp}.json` (or `.json.gz` if compressed)

## Compression

Archived logs are automatically compressed using `gzip` if:
- Compression is enabled (default: true)
- The `gzip` command is available

Compressed files use the `.gz` extension:
- `clippy-lint-20241229_084815.jsonl` → `clippy-lint-20241229_084815.jsonl.gz`

To decompress:
```bash
gunzip clippy-lint-20241229_084815.jsonl.gz
```

## Configuration Examples

### Conservative (Long Retention)

Keep logs longer for debugging:

```bash
./scripts/cleanup-logs.sh \
  --retention-days 90 \
  --archive-retention-days 730 \
  --metrics-retention-days 180
```

### Aggressive (Short Retention)

Minimize disk usage:

```bash
./scripts/cleanup-logs.sh \
  --retention-days 7 \
  --archive-retention-days 90 \
  --metrics-retention-days 30
```

### Production (Balanced)

Recommended for production environments:

```bash
./scripts/cleanup-logs.sh \
  --retention-days 30 \
  --archive-retention-days 365 \
  --metrics-retention-days 90 \
  --compress
```

## Monitoring Cleanup

The cleanup script uses structured logging (if `logging-utils.sh` is available) and records:
- Number of logs deleted
- Number of metrics deleted
- Number of logs archived
- Number of archives compressed
- Number of old archives deleted

View cleanup metrics:
```bash
# View latest cleanup log
ls -t /tmp/goose-logs/cleanup-logs-*.jsonl | head -1 | xargs cat | jq '.'

# View cleanup metrics
ls -t /tmp/goose-logs/cleanup-logs-metrics-*.json | head -1 | xargs cat | jq '.'
```

## Troubleshooting

### Script fails with "stat: command not found"

The script requires standard Unix utilities. On some minimal systems, you may need to install `coreutils`.

### Compression not working

Check if `gzip` is installed:
```bash
which gzip
```

If not installed, compression will be skipped (the script continues without compression).

### Date calculation fails

The script uses `date -d` (GNU date) or `date -v` (BSD date). If your system doesn't support either, you may need to adjust the date calculation logic.

### Permissions errors

Ensure the script has permissions to:
- Read log files
- Write to archive directory
- Delete log files

```bash
# Check permissions
ls -la /tmp/goose-logs/
ls -la /tmp/goose-logs/archive/

# Fix permissions if needed
chmod 755 /tmp/goose-logs/
chmod 755 /tmp/goose-logs/archive/
```

## Best Practices

1. **Run dry-run first**: Always test with `--dry-run` before running cleanup
2. **Monitor disk usage**: Regularly check disk space in log directories
3. **Review archived logs**: Periodically review archived logs to ensure important data is being preserved
4. **Automate cleanup**: Set up automated cleanup via cron or systemd
5. **Adjust retention**: Adjust retention periods based on your storage capacity and debugging needs
6. **Backup archives**: Consider backing up archive directories for critical systems

## Related Documentation

- `LOGGING_IMPROVEMENTS.md` - Structured logging implementation details
- `logging-utils.sh` - Logging utilities used by scripts
- `IMPLEMENTATION_SUMMARY.md` - Implementation summary

