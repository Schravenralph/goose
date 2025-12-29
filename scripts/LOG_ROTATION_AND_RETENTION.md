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

#### Cron Job Installation (Recommended)

The easiest way to set up automated log rotation is using the provided installation script:

```bash
# Install user-level cron job (daily at 2 AM)
./scripts/install-cron-log-rotation.sh

# Install with custom schedule (daily at 3 AM)
./scripts/install-cron-log-rotation.sh --schedule "0 3 * * *"

# Install system-level cron (requires sudo)
sudo ./scripts/install-cron-log-rotation.sh --type system

# Install with custom log directory
./scripts/install-cron-log-rotation.sh --log-dir /var/log/goose
```

The installation script will:
- Create a wrapper script that handles PATH and environment variables
- Set up error handling and logging for cron execution
- Install the cron job (user-level or system-level)
- Configure logging to capture cron execution output

**Uninstallation:**

```bash
# Uninstall cron job (auto-detects installation type)
./scripts/uninstall-cron-log-rotation.sh

# Uninstall user-level cron only
./scripts/uninstall-cron-log-rotation.sh --type user

# Uninstall system-level cron (requires sudo)
sudo ./scripts/uninstall-cron-log-rotation.sh --type system
```

**Verification:**

```bash
# Check user-level cron
crontab -l

# Check system-level cron
sudo cat /etc/cron.d/goose-log-rotation

# View cron execution logs
tail -f /tmp/goose-logs/cron-rotation.log
```

#### Manual Cron Setup

Alternatively, you can manually set up a cron job:

```bash
# Add to crontab (runs daily at 2 AM)
0 2 * * * /path/to/goose/scripts/rotate-logs.sh
```

**Note:** When setting up manually, ensure:
- The script path is absolute
- PATH is set correctly in the cron environment
- Output is redirected to a log file for debugging

#### Systemd Timer Installation (Linux)

For Linux systems using systemd, you can use systemd timers instead of cron. Systemd timers provide better logging, dependency management, and integration with the systemd journal.

**Installation:**

```bash
# Install user-level systemd timer (daily at 2 AM)
./scripts/install-systemd-log-rotation.sh

# Install system-level systemd timer (requires sudo)
sudo ./scripts/install-systemd-log-rotation.sh --type system

# Install with custom schedule (daily at 3 AM)
./scripts/install-systemd-log-rotation.sh --schedule "*-*-* 03:00:00"

# Install with weekly schedule
./scripts/install-systemd-log-rotation.sh --schedule weekly
```

The installation script will:
- Create systemd service and timer unit files
- Configure environment variables for log rotation
- Enable and start the timer automatically
- Set up proper logging to systemd journal

**Uninstallation:**

```bash
# Uninstall systemd timer (auto-detects installation type)
./scripts/uninstall-systemd-log-rotation.sh

# Uninstall user-level systemd timer only
./scripts/uninstall-systemd-log-rotation.sh --type user

# Uninstall system-level systemd timer (requires sudo)
sudo ./scripts/uninstall-systemd-log-rotation.sh --type system
```

**Verification:**

```bash
# Check timer status (user-level)
systemctl --user status goose-log-rotation.timer
systemctl --user list-timers goose-log-rotation.timer

# Check timer status (system-level)
sudo systemctl status goose-log-rotation.timer
sudo systemctl list-timers goose-log-rotation.timer

# View service logs (user-level)
journalctl --user -u goose-log-rotation.service

# View service logs (system-level)
sudo journalctl -u goose-log-rotation.service

# View recent rotation logs
journalctl --user -u goose-log-rotation.service --since "1 hour ago"
```

**Systemd Timer Schedule Format:**

- `daily` - Daily at 2:00 AM (default)
- `weekly` - Weekly on Monday at 2:00 AM
- `hourly` - Every hour
- `"*-*-* 03:00:00"` - Daily at 3:00 AM
- `"Mon *-*-* 02:00:00"` - Every Monday at 2:00 AM
- `"*-*-01 02:00:00"` - First day of month at 2:00 AM

See `systemd.time(7)` for more OnCalendar format options.

**Manual Systemd Setup:**

If you prefer to set up systemd units manually, you can copy the template files from `scripts/goose-log-rotation.service` and `scripts/goose-log-rotation.timer` to the appropriate systemd directory and customize them.

#### Script-Triggered Rotation (Automatic)

Script-triggered rotation automatically runs when scripts execute, checking if rotation is needed based on log file size or count thresholds. This provides immediate rotation when logs are generated, complementing scheduled rotation.

**How it works:**
- Automatically checks rotation thresholds when scripts using `logging-utils.sh` exit
- Triggers rotation asynchronously in the background to avoid blocking script execution
- Uses file locking to prevent concurrent rotations
- Only rotates bash script logs (not Rust logs) to avoid interference with active processes

**Configuration:**

```bash
# Enable/disable script-triggered rotation (default: true)
export GOOSE_LOG_ROTATION_ENABLED=true

# Size threshold in MB (default: 50MB)
# Rotation triggers when total log directory size exceeds this
export GOOSE_LOG_ROTATION_SIZE_THRESHOLD_MB=50

# Count threshold (default: 100 files)
# Rotation triggers when number of log files exceeds this
export GOOSE_LOG_ROTATION_COUNT_THRESHOLD=100

# Deferred rotation (default: true)
# If true, rotation runs in background detached from script
# If false, rotation runs in background but script waits briefly
export GOOSE_LOG_ROTATION_DEFERRED=true
```

**Behavior:**
- Rotation is triggered automatically when scripts exit if thresholds are exceeded
- Runs asynchronously to avoid blocking script execution
- File locking prevents multiple concurrent rotations
- Metrics are recorded for rotation trigger events
- Works alongside cron-based rotation (complementary, not replacement)

**Metrics:**
- `rotation_triggered`: Count of times rotation was triggered
- `rotation_skipped`: Count of times rotation was skipped (lock held)
- `rotation_trigger_count`: Total rotation trigger counter

**Note:** Script-triggered rotation complements scheduled rotation. Scheduled rotation ensures regular cleanup even during low-activity periods, while script-triggered rotation handles immediate needs during heavy usage.

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

