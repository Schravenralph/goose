# Cron Log Rotation Setup Guide

This guide explains how to set up automated log rotation using cron jobs for Goose logs.

## Overview

The cron log rotation setup provides automated, scheduled log rotation for both bash script logs and Rust application logs. It includes:

- **Installation script**: Automatically sets up cron job with proper configuration
- **Uninstallation script**: Safely removes cron job and wrapper scripts
- **Error handling**: Captures and logs cron execution output
- **Cross-platform support**: Works on Linux and macOS
- **Flexible installation**: Supports user-level and system-level cron

## Quick Start

### Installation

```bash
# Install user-level cron (recommended for most users)
cd /path/to/goose
./scripts/install-cron-log-rotation.sh
```

This will:
1. Create a wrapper script that handles PATH and environment variables
2. Install a cron job that runs daily at 2 AM
3. Set up logging for cron execution output

### Uninstallation

```bash
# Remove cron job and wrapper script
./scripts/uninstall-cron-log-rotation.sh
```

## Installation Options

### User-Level Cron (Default)

User-level cron runs as the current user and doesn't require root privileges:

```bash
# Basic installation (daily at 2 AM)
./scripts/install-cron-log-rotation.sh

# Custom schedule (daily at 3 AM)
./scripts/install-cron-log-rotation.sh --schedule "0 3 * * *"

# Weekly rotation (Sunday at 2 AM)
./scripts/install-cron-log-rotation.sh --schedule "0 2 * * 0"

# Custom log directory
./scripts/install-cron-log-rotation.sh --log-dir /var/log/goose
```

**Advantages:**
- No root/sudo required
- User-specific configuration
- Easy to install and remove

**Limitations:**
- Only runs when user is logged in (on some systems)
- User-specific crontab

### System-Level Cron

System-level cron runs as root and works system-wide:

```bash
# Install system-level cron
sudo ./scripts/install-cron-log-rotation.sh --type system

# Custom schedule
sudo ./scripts/install-cron-log-rotation.sh --type system --schedule "0 2 * * *"
```

**Advantages:**
- Runs regardless of user login status
- System-wide configuration
- Suitable for production servers

**Requirements:**
- Root/sudo access
- System administrator privileges

## Cron Schedule Format

The cron schedule follows the standard format:

```
Minute Hour Day Month Weekday
*      *    *   *     *
```

### Common Schedules

| Schedule | Description | Example |
|----------|-------------|---------|
| `0 2 * * *` | Daily at 2 AM | `--schedule "0 2 * * *"` |
| `0 3 * * *` | Daily at 3 AM | `--schedule "0 3 * * *"` |
| `0 2 * * 0` | Weekly on Sunday at 2 AM | `--schedule "0 2 * * 0"` |
| `0 2 1 * *` | Monthly on 1st at 2 AM | `--schedule "0 2 1 * *"` |
| `0 */6 * * *` | Every 6 hours | `--schedule "0 */6 * * *"` |
| `0 2 * * 1-5` | Weekdays at 2 AM | `--schedule "0 2 * * 1-5"` |

### Schedule Components

- **Minute**: 0-59 (or `*` for every minute)
- **Hour**: 0-23 (or `*` for every hour)
- **Day**: 1-31 (or `*` for every day)
- **Month**: 1-12 (or `*` for every month)
- **Weekday**: 0-7 (0 and 7 = Sunday, or `*` for every day)

## Configuration

### Environment Variables

The installation script supports various environment variables for configuration:

```bash
# Cron schedule (default: "0 2 * * *")
export GOOSE_CRON_SCHEDULE="0 3 * * *"

# Installation type (default: "user")
export GOOSE_CRON_INSTALL_TYPE="system"

# Cron log directory (default: "/tmp/goose-logs")
export GOOSE_CRON_LOG_DIR="/var/log/goose"

# Log rotation configuration
export LOG_DIR="/tmp/goose-logs"
export GOOSE_LOG_DETAILED_RETENTION_DAYS=7
export GOOSE_LOG_SUMMARY_RETENTION_DAYS=30
export GOOSE_LOG_ARCHIVE_RETENTION_DAYS=365
export GOOSE_LOG_COMPRESS_AFTER_DAYS=7
export GOOSE_LOG_MAX_SIZE_MB=100

# Install with environment variables
./scripts/install-cron-log-rotation.sh
```

### Wrapper Script

The installation script creates a wrapper script (`cron-rotate-logs-wrapper.sh`) that:

1. Sets up PATH to include common binary locations
2. Configures environment variables for log rotation
3. Redirects output to a log file for debugging
4. Handles errors and logs execution status

The wrapper script is automatically generated and should not be edited manually.

## Verification

### Check Installation

**User-level cron:**
```bash
# List current crontab
crontab -l

# Look for "Goose log rotation cron job" entry
```

**System-level cron:**
```bash
# Check system cron file
sudo cat /etc/cron.d/goose-log-rotation

# Verify file exists and is readable
ls -l /etc/cron.d/goose-log-rotation
```

### View Execution Logs

Cron execution output is logged to a file:

```bash
# View cron rotation log
tail -f /tmp/goose-logs/cron-rotation.log

# Or custom log directory
tail -f /var/log/goose/cron-rotation.log
```

The log file contains:
- Execution start/end timestamps
- Rotation script output
- Error messages (if any)
- Exit codes

### Test Manual Execution

You can test the wrapper script manually:

```bash
# Run wrapper script directly
./scripts/cron-rotate-logs-wrapper.sh

# Check exit code
echo $?

# View output
cat /tmp/goose-logs/cron-rotation.log
```

## Troubleshooting

### Cron Job Not Running

**Check cron service:**
```bash
# Linux (systemd)
sudo systemctl status cron

# macOS
sudo launchctl list | grep cron
```

**Verify cron job exists:**
```bash
# User-level
crontab -l | grep goose

# System-level
sudo cat /etc/cron.d/goose-log-rotation
```

**Check cron logs:**
```bash
# Linux
sudo grep CRON /var/log/syslog | tail -20

# macOS
grep cron /var/log/system.log | tail -20
```

### Permission Issues

**Script not executable:**
```bash
chmod +x scripts/rotate-logs.sh
chmod +x scripts/install-cron-log-rotation.sh
chmod +x scripts/uninstall-cron-log-rotation.sh
```

**Log directory not writable:**
```bash
# Create and set permissions
mkdir -p /tmp/goose-logs
chmod 755 /tmp/goose-logs
```

### PATH Issues

If the rotation script fails due to missing commands, the wrapper script sets PATH automatically. If issues persist:

1. Check wrapper script PATH settings
2. Verify required commands are in PATH: `which bash`, `which gzip`, etc.
3. Update wrapper script if needed (will be regenerated on reinstall)

### Timezone Issues

The wrapper script uses the system timezone. To set a specific timezone:

```bash
# Set timezone in wrapper script (before installation)
export TZ="America/New_York"
./scripts/install-cron-log-rotation.sh
```

Or edit the wrapper script after installation (note: it will be regenerated on reinstall).

### Rotation Not Working

**Check rotation script:**
```bash
# Test rotation script manually
./scripts/rotate-logs.sh

# Check for errors
echo $?
```

**Verify log directories:**
```bash
# Check bash log directory
ls -la /tmp/goose-logs/

# Check Rust log directory
ls -la ~/.local/share/goose/logs/
```

**Check environment variables:**
```bash
# View wrapper script to see configured variables
cat scripts/cron-rotate-logs-wrapper.sh
```

## Uninstallation

### Automatic Detection

The uninstallation script can auto-detect the installation type:

```bash
# Auto-detect and uninstall
./scripts/uninstall-cron-log-rotation.sh
```

### Manual Uninstallation

**User-level cron:**
```bash
# Remove from crontab
crontab -l | grep -v "goose-log-rotation\|cron-rotate-logs-wrapper" | crontab -

# Remove wrapper script
rm -f scripts/cron-rotate-logs-wrapper.sh
```

**System-level cron:**
```bash
# Remove system cron file
sudo rm -f /etc/cron.d/goose-log-rotation

# Remove wrapper script
rm -f scripts/cron-rotate-logs-wrapper.sh
```

## Best Practices

1. **Test First**: Test the rotation script manually before installing cron
2. **Monitor Logs**: Regularly check cron execution logs for errors
3. **Schedule Appropriately**: Choose a schedule that doesn't conflict with peak usage
4. **Retention Settings**: Adjust retention periods based on disk space and compliance needs
5. **Backup Critical Logs**: Ensure critical logs are archived before rotation
6. **Documentation**: Document custom schedules and configurations

## Platform-Specific Notes

### Linux

- Cron service is typically `cron` or `crond`
- System cron files in `/etc/cron.d/` require specific format
- Logs may appear in `/var/log/syslog` or `/var/log/cron`

### macOS

- Uses `launchd` for system services, but `cron` still works for user jobs
- User crontab works the same as Linux
- System-wide cron requires different approach (consider launchd instead)

## Related Documentation

- [Log Rotation and Retention](./LOG_ROTATION_AND_RETENTION.md) - Detailed rotation policies
- [Logging Improvements](./LOGGING_IMPROVEMENTS.md) - Structured logging implementation
- [rotate-logs.sh](./rotate-logs.sh) - Rotation script documentation

## Support

For issues or questions:
1. Check cron execution logs: `/tmp/goose-logs/cron-rotation.log`
2. Test rotation script manually: `./scripts/rotate-logs.sh`
3. Verify cron job configuration: `crontab -l` or `sudo cat /etc/cron.d/goose-log-rotation`
4. Review this troubleshooting guide

