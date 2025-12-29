# Metrics Dashboard Production Deployment Guide

This guide covers deploying the Goose Metrics Dashboard in a production environment with security best practices.

## Prerequisites

- Python 3.7 or higher
- Access to metrics directory containing JSON metrics files
- SSL/TLS certificate (for HTTPS)
- Reverse proxy (nginx or Apache) recommended
- Systemd (for service management) or similar init system

## Quick Start

### 1. Basic Setup

```bash
# Navigate to scripts directory
cd goose/scripts

# Run with authentication
python3 serve-metrics-dashboard.py \
  --host 0.0.0.0 \
  --port 8080 \
  --auth-username admin \
  --auth-password "your-secure-password" \
  --audit-log /var/log/goose-dashboard-audit.log \
  --metrics-dir /var/lib/goose/metrics
```

### 2. Production Setup with nginx

#### Step 1: Create Systemd Service

Create `/etc/systemd/system/goose-metrics-dashboard.service`:

```ini
[Unit]
Description=Goose Metrics Dashboard Server
After=network.target

[Service]
Type=simple
User=goose
Group=goose
WorkingDirectory=/opt/goose/scripts
ExecStart=/usr/bin/python3 /opt/goose/scripts/serve-metrics-dashboard.py \
  --host 127.0.0.1 \
  --port 8080 \
  --auth-username admin \
  --auth-password "CHANGE_THIS_PASSWORD" \
  --audit-log /var/log/goose-dashboard-audit.log \
  --metrics-dir /var/lib/goose/metrics \
  --rate-limit 100 \
  --rate-limit-window 60
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Important**: Replace `CHANGE_THIS_PASSWORD` with a strong password!

#### Step 2: Create nginx Configuration

Create `/etc/nginx/sites-available/goose-metrics-dashboard`:

```nginx
server {
    listen 80;
    server_name metrics.yourdomain.com;
    
    # Redirect HTTP to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name metrics.yourdomain.com;
    
    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/metrics.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/metrics.yourdomain.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Proxy Settings
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # Logging
    access_log /var/log/nginx/goose-metrics-access.log;
    error_log /var/log/nginx/goose-metrics-error.log;
}
```

#### Step 3: Enable and Start Services

```bash
# Enable nginx site
sudo ln -s /etc/nginx/sites-available/goose-metrics-dashboard /etc/nginx/sites-enabled/
sudo nginx -t  # Test configuration
sudo systemctl reload nginx

# Enable and start dashboard service
sudo systemctl daemon-reload
sudo systemctl enable goose-metrics-dashboard
sudo systemctl start goose-metrics-dashboard

# Check status
sudo systemctl status goose-metrics-dashboard
```

### 3. SSL Certificate Setup (Let's Encrypt)

```bash
# Install certbot
sudo apt-get update
sudo apt-get install certbot python3-certbot-nginx

# Obtain certificate
sudo certbot --nginx -d metrics.yourdomain.com

# Auto-renewal is set up automatically
```

## Configuration Options

### Command-Line Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--host` | `localhost` | Host to bind to (use `0.0.0.0` for all interfaces, `127.0.0.1` behind proxy) |
| `--port` | `8080` | Port to listen on |
| `--metrics-dir` | `/tmp/goose-logs` | Directory containing metrics JSON files |
| `--auth-username` | None | Basic auth username (enables authentication) |
| `--auth-password` | None | Basic auth password (required if username set) |
| `--audit-log` | None | Path to audit log file (logs to stderr if not set) |
| `--rate-limit` | `100` | Max requests per window per IP |
| `--rate-limit-window` | `60` | Rate limit window in seconds |

### Environment Variables

You can also use environment variables for sensitive configuration:

```bash
export GOOSE_DASHBOARD_AUTH_USERNAME="admin"
export GOOSE_DASHBOARD_AUTH_PASSWORD="secure-password"
```

Then modify the service file to read from environment:
```ini
Environment="GOOSE_DASHBOARD_AUTH_USERNAME=admin"
Environment="GOOSE_DASHBOARD_AUTH_PASSWORD=secure-password"
ExecStart=/usr/bin/python3 /opt/goose/scripts/serve-metrics-dashboard.py \
  --auth-username "$GOOSE_DASHBOARD_AUTH_USERNAME" \
  --auth-password "$GOOSE_DASHBOARD_AUTH_PASSWORD" \
  ...
```

## Directory Structure

Recommended production directory structure:

```
/opt/goose/
├── scripts/
│   ├── serve-metrics-dashboard.py
│   └── metrics-dashboard.html
/var/lib/goose/
└── metrics/
    ├── script1-metrics-20250102_120000.json
    └── script2-metrics-20250102_120000.json
/var/log/
├── goose-dashboard-audit.log
└── goose-dashboard-error.log
```

## File Permissions

Set appropriate file permissions:

```bash
# Create goose user (if not exists)
sudo useradd -r -s /bin/false goose

# Set ownership
sudo chown -R goose:goose /opt/goose
sudo chown -R goose:goose /var/lib/goose
sudo chown -R goose:goose /var/log/goose-dashboard-audit.log

# Set permissions
sudo chmod 755 /opt/goose/scripts
sudo chmod 644 /opt/goose/scripts/*.py
sudo chmod 755 /opt/goose/scripts/serve-metrics-dashboard.py
sudo chmod 750 /var/lib/goose/metrics
sudo chmod 640 /var/log/goose-dashboard-audit.log
```

## Log Rotation

Configure log rotation for audit logs:

Create `/etc/logrotate.d/goose-metrics-dashboard`:

```
/var/log/goose-dashboard-audit.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 goose goose
    sharedscripts
    postrotate
        systemctl reload goose-metrics-dashboard > /dev/null 2>&1 || true
    endscript
}
```

## Firewall Configuration

Restrict access using firewall rules:

```bash
# UFW example (Ubuntu)
sudo ufw allow from 10.0.0.0/8 to any port 443  # Internal network only
sudo ufw allow from 192.168.1.0/24 to any port 443  # VPN network

# Or use iptables
sudo iptables -A INPUT -p tcp --dport 443 -s 10.0.0.0/8 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j DROP
```

## Monitoring

### Health Check

Create a simple health check script:

```bash
#!/bin/bash
# /usr/local/bin/check-goose-dashboard.sh

curl -f -u "admin:password" https://metrics.yourdomain.com/api/metrics > /dev/null 2>&1
exit $?
```

Add to cron for monitoring:
```bash
*/5 * * * * /usr/local/bin/check-goose-dashboard.sh || systemctl restart goose-metrics-dashboard
```

### Metrics Collection

Monitor the dashboard itself:
- Check systemd service status
- Monitor audit logs for errors
- Track rate limit violations
- Monitor disk space for metrics directory

## Troubleshooting

### Service Won't Start

```bash
# Check logs
sudo journalctl -u goose-metrics-dashboard -n 50

# Check permissions
ls -la /opt/goose/scripts/serve-metrics-dashboard.py
ls -la /var/lib/goose/metrics

# Test manually
sudo -u goose python3 /opt/goose/scripts/serve-metrics-dashboard.py --help
```

### Authentication Not Working

- Verify username and password in service file
- Check nginx proxy headers are set correctly
- Test directly (bypass nginx): `curl -u user:pass http://127.0.0.1:8080`

### Rate Limiting Too Aggressive

- Increase limits: `--rate-limit 200 --rate-limit-window 120`
- Check if multiple users share same IP (behind NAT)
- Consider IP whitelisting for trusted networks

### SSL Certificate Issues

```bash
# Check certificate
sudo certbot certificates

# Renew manually
sudo certbot renew

# Test nginx config
sudo nginx -t
```

## Backup and Recovery

### Backup Metrics Data

```bash
# Backup metrics directory
tar -czf goose-metrics-backup-$(date +%Y%m%d).tar.gz /var/lib/goose/metrics

# Backup configuration
tar -czf goose-dashboard-config-$(date +%Y%m%d).tar.gz \
  /etc/systemd/system/goose-metrics-dashboard.service \
  /etc/nginx/sites-available/goose-metrics-dashboard
```

### Recovery

1. Restore metrics directory
2. Restore configuration files
3. Restart services
4. Verify functionality

## Upgrades

When upgrading the dashboard:

1. **Backup current installation**
2. **Stop the service**: `sudo systemctl stop goose-metrics-dashboard`
3. **Update files**: Copy new `serve-metrics-dashboard.py`
4. **Test configuration**: Run manually to verify
5. **Restart service**: `sudo systemctl start goose-metrics-dashboard`
6. **Verify**: Check logs and test dashboard access

## Security Checklist

Before going live, verify:

- [ ] Authentication is enabled
- [ ] Strong password is set
- [ ] HTTPS is configured and working
- [ ] Firewall rules restrict access
- [ ] Audit logging is enabled
- [ ] File permissions are correct
- [ ] Service runs as non-root user
- [ ] Log rotation is configured
- [ ] SSL certificate auto-renewal is set up
- [ ] Monitoring/alerting is configured
- [ ] Backup strategy is in place

## Support

For issues or questions:
- Check logs: `sudo journalctl -u goose-metrics-dashboard`
- Review audit logs: `tail -f /var/log/goose-dashboard-audit.log`
- See security documentation: `METRICS_DASHBOARD_SECURITY.md`
