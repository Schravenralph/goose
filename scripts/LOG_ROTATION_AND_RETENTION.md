# Log Rotation and Retention Policies

This document describes the log rotation and retention policies for Goose logs, covering both bash script logs and Rust application logs.

## Overview

Goose generates structured logs in two locations:
1. **Bash script logs**: `/tmp/goose-logs/` (configurable via `LOG_DIR`)
2. **Rust application logs**: `state_dir/logs/` (typically `~/.local/share/goose/logs/` on Linux)

Both locations are managed by rotation and retention policies to prevent disk space issues while maintaining logs for debugging and analysis.

## Retention Policy

The retention policy uses a three-tier approach:

### 1. Detailed Retention (7 days)
- **Default**: 7 days
- **Purpose**: Keep recent logs in full detail for immediate debugging
- **Action**: Logs are kept uncompressed and easily accessible

### 2. Summary Retention (30 days)
- **Default**: 30 days
- **Purpose**: Keep logs for trend analysis and periodic review
- **Action**: 
  - Logs older than detailed retention (7 days) are compressed
  - Critical logs (containing errors/failures) are archived separately
  - Logs are still accessible but compressed

### 3. Archive Retention (365 days)
- **Default**: 365 days (1 year)
- **Purpose**: Long-term storage for critical logs and compliance
- **Action**:
  - Only critical logs (errors, failures) are kept in archive
  - Regular logs older than summary retention are deleted
  - Archived logs are compressed

## Configuration

Retention periods can be configured via environment variables:

```bash
# Detailed retention (default: 7 days)
export GOOSE_LOG_DETAILED_RETENTION_DAYS=7

# Summary retention (default: 30 days)
export GOOSE_LOG_SUMMARY_RETENTION_DAYS=30

# Archive retention (default: 365 days)
export GOOSE_LOG_ARCHIVE_RETENTION_DAYS=365

# Compression threshold (default: 7 days)
export GOOSE_LOG_COMPRESS_AFTER_DAYS=7

# Maximum log file size before rotation (default: 100MB)
export GOOSE_LOG_MAX_SIZE_MB=100

# Archive directory (default: $LOG_DIR/archive for bash logs)
export GOOSE_LOG_ARCHIVE_DIR=/path/to/archive
```

## Usage

### Manual Rotation

Run the rotation script manually:

```bash
# Rotate both bash and Rust logs
./scripts/rotate-logs.sh

# Rotate only bash script logs
./scripts/rotate-logs.sh true false

# Rotate only Rust logs
./scripts/rotate-logs.sh false true
```

### Automated Rotation

Set up a cron job for automatic rotation:

```bash
# Add to crontab (runs daily at 2 AM)
0 2 * * * /path/to/goose/scripts/rotate-logs.sh
```

Or use systemd timer (create `/etc/systemd/system/goose-log-rotation.service`):

```ini
[Unit]
Description=Goose Log Rotation
After=network.target

[Service]
Type=oneshot
ExecStart=/path/to/goose/scripts/rotate-logs.sh
Environment="GOOSE_LOG_DETAILED_RETENTION_DAYS=7"
Environment="GOOSE_LOG_SUMMARY_RETENTION_DAYS=30"
Environment="GOOSE_LOG_ARCHIVE_RETENTION_DAYS=365"
```

And `/etc/systemd/system/goose-log-rotation.timer`:

```ini
[Unit]
Description=Goose Log Rotation Timer
Requires=goose-log-rotation.service

[Timer]
OnCalendar=daily
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable with:
```bash
sudo systemctl enable goose-log-rotation.timer
sudo systemctl start goose-log-rotation.timer
```

## Log Rotation Features

### Size-Based Rotation
- Logs larger than the configured maximum size (default: 100MB) are automatically compressed
- Prevents individual log files from consuming excessive disk space

### Compression
- Logs older than the compression threshold are compressed using `gzip`, `bzip2`, or `xz` (in order of preference)
- Compression reduces disk usage significantly while keeping logs accessible

### Critical Log Archiving
- Logs containing `ERROR` or `FATAL` level entries are automatically archived
- Archived logs are stored in a separate `archive/critical/` directory
- Critical logs are kept for the full archive retention period (1 year by default)

### Automatic Cleanup
- Old log files and empty directories are automatically removed
- Date-based subdirectories are cleaned up when empty
- Archive directories are managed separately

## Log Locations

### Bash Script Logs
- **Location**: `/tmp/goose-logs/` (or `$LOG_DIR`)
- **Format**: `{script-name}-{timestamp}.jsonl` (logs)
- **Format**: `{script-name}-metrics-{timestamp}.json` (metrics)
- **Archive**: `/tmp/goose-logs/archive/critical/`

### Rust Application Logs
- **Location**: `~/.local/share/goose/logs/` (Linux) or `~/Library/Application Support/goose/logs/` (macOS)
- **Structure**: `logs/{component}/{date}/` (for date-based subdirectories)
- **Format**: `{timestamp}-{name}.log` (server logs)
- **Archive**: `logs/{component}/archive/`

## Examples

### Check Log Sizes
```bash
# Check bash log directory size
du -sh /tmp/goose-logs/

# Check Rust log directory size
du -sh ~/.local/share/goose/logs/
```

### View Recent Logs
```bash
# View recent bash script logs
ls -lth /tmp/goose-logs/*.jsonl | head -10

# View recent Rust logs
ls -lth ~/.local/share/goose/logs/server/*/*.log | head -10
```

### Search Archived Critical Logs
```bash
# Find archived critical logs
find /tmp/goose-logs/archive/critical -name "*.jsonl*" -o -name "*.log*"

# Search for specific errors in archived logs
zgrep -i "error" /tmp/goose-logs/archive/critical/*.gz
```

### Manual Cleanup
```bash
# Remove logs older than 30 days manually
find /tmp/goose-logs -name "*.jsonl" -mtime +30 -delete
find /tmp/goose-logs -name "*.json" -mtime +30 -delete
```

## Best Practices

1. **Regular Rotation**: Run rotation daily to prevent disk space issues
2. **Monitor Disk Usage**: Check log directory sizes regularly
3. **Adjust Retention**: Adjust retention periods based on your needs and available disk space
4. **Archive Critical Logs**: Ensure critical logs are archived for long-term analysis
5. **Compression**: Enable compression to save disk space while keeping logs accessible
6. **Test Rotation**: Test rotation scripts in a non-production environment first

## Troubleshooting

### Logs Not Rotating
- Check that the rotation script has execute permissions: `chmod +x scripts/rotate-logs.sh`
- Verify log directories exist and are writable
- Check environment variables are set correctly

### Disk Space Issues
- Reduce retention periods if disk space is limited
- Increase compression threshold to compress logs earlier
- Manually run rotation: `./scripts/rotate-logs.sh`

### Missing Critical Logs
- Check archive directory: `/tmp/goose-logs/archive/critical/` or `logs/{component}/archive/`
- Verify logs contain ERROR or FATAL level entries (required for archiving)
- Check archive retention period is sufficient

## Related Documentation

- [Logging Improvements](./LOGGING_IMPROVEMENTS.md) - Structured logging implementation
- [Implementation Summary](./IMPLEMENTATION_SUMMARY.md) - Logging infrastructure overview

