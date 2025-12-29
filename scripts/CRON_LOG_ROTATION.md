# Automated Log Rotation with Cron Jobs

This guide explains how to set up automated log rotation using cron jobs for Goose logs. This provides production-ready log management that runs automatically on a schedule.

## Overview

The automated log rotation system uses cron jobs to run the `rotate-logs.sh` script on a regular schedule. This ensures logs are rotated, compressed, and cleaned up automatically without manual intervention.

## Prerequisites

- `rotate-logs.sh` script must be available in `scripts/` directory
- `cron` service must be running (usually enabled by default on Linux/macOS)
- Appropriate permissions to install cron jobs (user-level or root for system-level)

## Installation

### Quick Start

Install daily log rotation (runs at 2 AM every day):

```bash
./scripts/install-cron-log-rotation.sh
```

### Installation Options

#### Daily Rotation (Default)

```bash
./scripts/install-cron-log-rotation.sh --daily
# or
./scripts/install-cron-log-rotation.sh -d
```

Runs every day at 2:00 AM.

#### Weekly Rotation

```bash
./scripts/install-cron-log-rotation.sh --weekly
# or
./scripts/install-cron-log-rotation.sh -w
```

Runs every Sunday at 2:00 AM.

#### Custom Schedule

```bash
./scripts/install-cron-log-rotation.sh --schedule "0 3 * * 1"
```

This example runs every Monday at 3:00 AM.

**Cron Schedule Format**: `minute hour day month weekday`

Common examples:
- `0 2 * * *` - Daily at 2:00 AM
- `0 2 * * 0` - Weekly on Sunday at 2:00 AM
- `0 */6 * * *` - Every 6 hours
- `0 0 1 * *` - Monthly on the 1st at midnight
- `0 2 * * 1-5` - Weekdays (Monday-Friday) at 2:00 AM

#### User-Level vs System-Level

**User-Level Cron (Default)**:
- Runs as the current user
- No sudo required
- Installed in user's crontab

```bash
./scripts/install-cron-log-rotation.sh --user
```

**System-Level Cron**:
- Runs as root
- Requires sudo
- Installed in `/etc/cron.d/goose-log-rotation`

```bash
sudo ./scripts/install-cron-log-rotation.sh --system
```

#### Custom Log File

Specify where cron execution logs are written:

```bash
./scripts/install-cron-log-rotation.sh --log-file /var/log/goose-cron.log
```

Default: `/tmp/goose-logs/cron/rotate-logs-cron.log`

## Verification

### Check if Cron Job is Installed

**User-Level Cron**:
```bash
crontab -l | grep rotate-logs
```

**System-Level Cron**:
```bash
cat /etc/cron.d/goose-log-rotation
```

### View Cron Execution Logs

```bash
# Default location
tail -f /tmp/goose-logs/cron/rotate-logs-cron.log

# Custom location (if specified during installation)
tail -f /path/to/your/cron.log
```

### Test the Rotation Script Manually

```bash
./scripts/rotate-logs.sh
```

## Uninstallation

### Remove User-Level Cron

```bash
./scripts/uninstall-cron-log-rotation.sh
# or
./scripts/uninstall-cron-log-rotation.sh --user
```

### Remove System-Level Cron

```bash
sudo ./scripts/uninstall-cron-log-rotation.sh --system
```

### Remove Both User and System Cron

```bash
sudo ./scripts/uninstall-cron-log-rotation.sh --all
```

## Troubleshooting

### Cron Job Not Running

1. **Check if cron service is running**:
   ```bash
   # Linux (systemd)
   systemctl status cron
   # or
   systemctl status crond
   
   # macOS
   sudo launchctl list | grep cron
   ```

2. **Check cron logs**:
   ```bash
   # Linux
   sudo tail -f /var/log/syslog | grep CRON
   # or
   sudo tail -f /var/log/cron
   
   # macOS
   log show --predicate 'process == "cron"' --last 1h
   ```

3. **Verify cron job syntax**:
   ```bash
   crontab -l
   ```

4. **Check PATH in cron environment**:
   - Cron jobs run with a minimal PATH
   - The installation script automatically sets PATH
   - If issues persist, check the cron log file for errors

### Permission Errors

- **User-level cron**: Ensure you have permission to edit your crontab
- **System-level cron**: Must run with `sudo`
- **Log directory**: Ensure the log directory is writable

### Script Not Found

If cron reports that `rotate-logs.sh` is not found:

1. Verify the script exists:
   ```bash
   ls -l scripts/rotate-logs.sh
   ```

2. Check the cron job path:
   ```bash
   crontab -l | grep rotate-logs
   ```

3. The installation script should use absolute paths automatically

### Logs Not Rotating

1. **Check if the script runs manually**:
   ```bash
   ./scripts/rotate-logs.sh
   ```

2. **Check cron execution logs**:
   ```bash
   tail -f /tmp/goose-logs/cron/rotate-logs-cron.log
   ```

3. **Verify log directories exist**:
   - Bash logs: `/tmp/goose-logs/` (or `$LOG_DIR`)
   - Rust logs: `~/.local/share/goose/logs` (Linux) or `~/Library/Application Support/goose/logs` (macOS)

### Timezone Issues

Cron jobs use the system timezone. To change the timezone:

```bash
# Check current timezone
timedatectl  # Linux
# or
systemsetup -gettimezone  # macOS

# Set timezone (Linux)
sudo timedatectl set-timezone America/New_York

# Set timezone (macOS)
sudo systemsetup -settimezone America/New_York
```

## Configuration

### Environment Variables

The rotation script respects these environment variables (set in cron entry if needed):

- `GOOSE_LOG_DETAILED_RETENTION_DAYS` - Detailed logs retention (default: 7 days)
- `GOOSE_LOG_SUMMARY_RETENTION_DAYS` - Summary logs retention (default: 30 days)
- `GOOSE_LOG_ARCHIVE_RETENTION_DAYS` - Archive retention (default: 365 days)
- `GOOSE_LOG_COMPRESS_AFTER_DAYS` - Compress logs after (default: 7 days)
- `GOOSE_LOG_MAX_SIZE_MB` - Max log size before rotation (default: 100 MB)
- `LOG_DIR` - Bash log directory (default: `/tmp/goose-logs`)
- `GOOSE_PATH_ROOT` - Goose root path for Rust logs

### Custom Configuration in Cron

To use custom environment variables, you can manually edit the crontab after installation:

```bash
crontab -e
```

Add environment variables before the command:

```
GOOSE_LOG_DETAILED_RETENTION_DAYS=14
GOOSE_LOG_SUMMARY_RETENTION_DAYS=60
0 2 * * * PATH="..." /path/to/rotate-logs.sh >> /path/to/log 2>&1
```

## Best Practices

1. **Start with daily rotation**: Daily rotation is usually sufficient for most use cases
2. **Monitor cron logs**: Regularly check cron execution logs for errors
3. **Test manually first**: Run `rotate-logs.sh` manually before setting up cron
4. **Use user-level cron for development**: System-level cron is better for production
5. **Set appropriate retention**: Adjust retention periods based on your disk space and compliance requirements
6. **Backup critical logs**: The rotation script automatically archives critical logs (errors, failures)

## Related Documentation

- `rotate-logs.sh` - The log rotation script
- `LOG_ROTATION_AND_RETENTION.md` - Detailed log rotation and retention policies
- `LOG_RETENTION.md` - Log retention configuration

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review cron execution logs
3. Test the rotation script manually
4. Check system cron logs for errors

