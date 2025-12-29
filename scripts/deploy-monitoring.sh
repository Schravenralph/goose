#!/bin/bash

# Automated deployment script for Goose monitoring tool integrations
# Usage: ./deploy-monitoring.sh [--prometheus] [--grafana] [--elk] [--datadog] [--all]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="deploy-monitoring"

# Source logging utilities
source "$SCRIPT_DIR/logging-utils.sh"

# Deployment flags
DEPLOY_PROMETHEUS=false
DEPLOY_GRAFANA=false
DEPLOY_ELK=false
DEPLOY_DATADOG=false
GOOSE_USER="${GOOSE_USER:-goose}"
GOOSE_HOME="${GOOSE_HOME:-/home/$GOOSE_USER/goose}"
LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
METRICS_DIR="${METRICS_DIR:-/tmp/goose-logs}"

# Parse arguments
if [[ $# -eq 0 ]]; then
    # Interactive mode
    echo "Goose Monitoring Deployment"
    echo "=========================="
    echo ""
    echo "Which monitoring tools would you like to deploy?"
    echo ""
    read -p "Deploy Prometheus exporter? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DEPLOY_PROMETHEUS=true
    fi
    
    read -p "Deploy Grafana dashboards? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DEPLOY_GRAFANA=true
    fi
    
    read -p "Deploy ELK Stack integration? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DEPLOY_ELK=true
    fi
    
    read -p "Deploy Datadog forwarder? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DEPLOY_DATADOG=true
    fi
else
    # Command line mode
    while [[ $# -gt 0 ]]; do
        case $1 in
            --prometheus)
                DEPLOY_PROMETHEUS=true
                shift
                ;;
            --grafana)
                DEPLOY_GRAFANA=true
                shift
                ;;
            --elk)
                DEPLOY_ELK=true
                shift
                ;;
            --datadog)
                DEPLOY_DATADOG=true
                shift
                ;;
            --all)
                DEPLOY_PROMETHEUS=true
                DEPLOY_GRAFANA=true
                DEPLOY_ELK=true
                DEPLOY_DATADOG=true
                shift
                ;;
            --user)
                GOOSE_USER="$2"
                GOOSE_HOME="/home/$GOOSE_USER/goose"
                shift 2
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --prometheus    Deploy Prometheus exporter"
                echo "  --grafana       Deploy Grafana dashboards"
                echo "  --elk           Deploy ELK Stack integration"
                echo "  --datadog       Deploy Datadog forwarder"
                echo "  --all           Deploy all available integrations"
                echo "  --user USER     Set Goose user (default: goose)"
                echo ""
                echo "If no options are provided, interactive mode will be used."
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v systemctl &> /dev/null; then
    log_error "systemctl is required but not installed"
    exit 1
fi

if ! id "$GOOSE_USER" &>/dev/null; then
    log_warn "User $GOOSE_USER does not exist. Creating..."
    useradd -r -s /bin/bash -d "/home/$GOOSE_USER" -m "$GOOSE_USER" || true
fi

# Ensure directories exist
mkdir -p "$LOG_DIR"
mkdir -p "$METRICS_DIR"
mkdir -p "/etc/goose-monitoring"
chown -R "$GOOSE_USER:$GOOSE_USER" "$LOG_DIR" "$METRICS_DIR" 2>/dev/null || true

# Deploy Prometheus Exporter
if [[ "$DEPLOY_PROMETHEUS" == "true" ]]; then
    log_info "Deploying Prometheus exporter..."
    
    # Check if exporter script exists
    if [[ ! -f "$GOOSE_HOME/scripts/prometheus-exporter.sh" ]]; then
        log_error "Prometheus exporter script not found at $GOOSE_HOME/scripts/prometheus-exporter.sh"
        exit 1
    fi
    
    # Make script executable
    chmod +x "$GOOSE_HOME/scripts/prometheus-exporter.sh"
    
    # Create service file
    cat > /etc/systemd/system/goose-prometheus-exporter.service <<EOF
[Unit]
Description=Goose Prometheus Metrics Exporter
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$GOOSE_USER
Group=$GOOSE_USER
WorkingDirectory=$GOOSE_HOME/scripts
ExecStart=$GOOSE_HOME/scripts/prometheus-exporter.sh --port 9090 --metrics-dir $METRICS_DIR
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=goose-prometheus-exporter

Environment="PROMETHEUS_EXPORTER_PORT=9090"
Environment="PROMETHEUS_METRICS_DIR=$METRICS_DIR"
Environment="LOG_DIR=$LOG_DIR"

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$LOG_DIR $METRICS_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable goose-prometheus-exporter
    systemctl start goose-prometheus-exporter
    
    # Wait a moment and check status
    sleep 2
    if systemctl is-active --quiet goose-prometheus-exporter; then
        log_info "✓ Prometheus exporter deployed and running"
    else
        log_warn "Prometheus exporter service started but may not be running. Check logs:"
        log_warn "  sudo journalctl -u goose-prometheus-exporter -n 50"
    fi
fi

# Deploy Grafana Dashboards
if [[ "$DEPLOY_GRAFANA" == "true" ]]; then
    log_info "Deploying Grafana dashboards..."
    
    if [[ ! -f "$GOOSE_HOME/scripts/grafana-dashboard-goose.json" ]]; then
        log_warn "Grafana dashboard file not found. Skipping dashboard import."
        log_warn "You can import it manually from: $GOOSE_HOME/scripts/grafana-dashboard-goose.json"
    else
        log_info "Grafana dashboard file found. Import manually:"
        log_info "  1. Open Grafana UI: http://localhost:3000"
        log_info "  2. Go to: Dashboards → Import"
        log_info "  3. Upload: $GOOSE_HOME/scripts/grafana-dashboard-goose.json"
    fi
fi

# Deploy ELK Stack Integration
if [[ "$DEPLOY_ELK" == "true" ]]; then
    log_info "Deploying ELK Stack integration..."
    
    # Check if Filebeat is installed
    if command -v filebeat &> /dev/null; then
        log_info "Filebeat is installed. Configuring..."
        
        # Backup existing config
        if [[ -f /etc/filebeat/filebeat.yml ]]; then
            cp /etc/filebeat/filebeat.yml /etc/filebeat/filebeat.yml.backup.$(date +%Y%m%d_%H%M%S)
        fi
        
        # Copy configuration
        if [[ -f "$GOOSE_HOME/scripts/filebeat-goose.yml.example" ]]; then
            cp "$GOOSE_HOME/scripts/filebeat-goose.yml.example" /etc/filebeat/filebeat.yml
            log_info "Filebeat configuration copied. Edit /etc/filebeat/filebeat.yml as needed."
            
            # Test configuration
            if filebeat test config &>/dev/null; then
                log_info "✓ Filebeat configuration is valid"
            else
                log_warn "Filebeat configuration test failed. Check: sudo filebeat test config"
            fi
            
            # Enable and start Filebeat
            systemctl enable filebeat
            systemctl start filebeat
            
            if systemctl is-active --quiet filebeat; then
                log_info "✓ Filebeat started successfully"
            else
                log_warn "Filebeat may not be running. Check: sudo systemctl status filebeat"
            fi
        else
            log_warn "Filebeat configuration example not found at $GOOSE_HOME/scripts/filebeat-goose.yml.example"
        fi
    else
        log_warn "Filebeat is not installed. Install it first:"
        log_warn "  Ubuntu/Debian: sudo apt-get install filebeat"
        log_warn "  RHEL/CentOS: sudo yum install filebeat"
    fi
fi

# Deploy Datadog Forwarder
if [[ "$DEPLOY_DATADOG" == "true" ]]; then
    log_info "Deploying Datadog forwarder..."
    
    # Check if forwarder script exists
    if [[ ! -f "$GOOSE_HOME/scripts/datadog-forwarder.sh" ]]; then
        log_error "Datadog forwarder script not found at $GOOSE_HOME/scripts/datadog-forwarder.sh"
        exit 1
    fi
    
    # Make script executable
    chmod +x "$GOOSE_HOME/scripts/datadog-forwarder.sh"
    
    # Get API key
    if [[ -f /etc/goose-monitoring/datadog.env ]]; then
        log_info "Datadog environment file exists. Checking API key..."
        if grep -q "DD_API_KEY=" /etc/goose-monitoring/datadog.env && ! grep -q "DD_API_KEY=your-api-key-here" /etc/goose-monitoring/datadog.env; then
            log_info "API key is configured"
        else
            log_warn "API key not configured. Please set DD_API_KEY in /etc/goose-monitoring/datadog.env"
        fi
    else
        log_info "Creating Datadog environment file..."
        cat > /etc/goose-monitoring/datadog.env <<EOF
# Datadog API Configuration
# Get your API key from: https://app.datadoghq.com/organization-settings/api-keys
DD_API_KEY=your-api-key-here
DD_SITE=datadoghq.com

# Log and metrics directories
LOG_DIR=$LOG_DIR
METRICS_DIR=$METRICS_DIR
EOF
        chmod 600 /etc/goose-monitoring/datadog.env
        log_warn "Please edit /etc/goose-monitoring/datadog.env and set your DD_API_KEY"
    fi
    
    # Create service file
    cat > /etc/systemd/system/goose-datadog-forwarder.service <<EOF
[Unit]
Description=Goose Datadog Log and Metrics Forwarder
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$GOOSE_USER
Group=$GOOSE_USER
WorkingDirectory=$GOOSE_HOME/scripts
EnvironmentFile=-/etc/goose-monitoring/datadog.env
ExecStart=$GOOSE_HOME/scripts/datadog-forwarder.sh --interval 60
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=goose-datadog-forwarder

Environment="LOG_DIR=$LOG_DIR"
Environment="METRICS_DIR=$METRICS_DIR"
Environment="DD_SITE=datadoghq.com"

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$LOG_DIR $METRICS_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable goose-datadog-forwarder
    
    # Check if API key is configured before starting
    if grep -q "DD_API_KEY=" /etc/goose-monitoring/datadog.env && ! grep -q "DD_API_KEY=your-api-key-here" /etc/goose-monitoring/datadog.env; then
        systemctl start goose-datadog-forwarder
        
        sleep 2
        if systemctl is-active --quiet goose-datadog-forwarder; then
            log_info "✓ Datadog forwarder deployed and running"
        else
            log_warn "Datadog forwarder service started but may not be running. Check logs:"
            log_warn "  sudo journalctl -u goose-datadog-forwarder -n 50"
        fi
    else
        log_warn "Datadog forwarder service created but not started (API key not configured)"
        log_warn "After setting DD_API_KEY, start with: sudo systemctl start goose-datadog-forwarder"
    fi
fi

# Summary
log_info "📊 Deployment Summary"
log_info "===================="

if [[ "$DEPLOY_PROMETHEUS" == "true" ]]; then
    if systemctl is-active --quiet goose-prometheus-exporter; then
        log_info "✓ Prometheus exporter: Running"
    else
        log_info "✗ Prometheus exporter: Not running"
    fi
fi

if [[ "$DEPLOY_DATADOG" == "true" ]]; then
    if systemctl is-active --quiet goose-datadog-forwarder; then
        log_info "✓ Datadog forwarder: Running"
    else
        log_info "✗ Datadog forwarder: Not running (check API key)"
    fi
fi

if [[ "$DEPLOY_ELK" == "true" ]]; then
    if systemctl is-active --quiet filebeat 2>/dev/null; then
        log_info "✓ Filebeat: Running"
    else
        log_info "✗ Filebeat: Not running or not installed"
    fi
fi

log_info ""
log_info "Next steps:"
log_info "1. Run validation: $GOOSE_HOME/scripts/validate-monitoring-deployment.sh"
log_info "2. Configure Prometheus to scrape: http://localhost:9090/metrics"
log_info "3. Import Grafana dashboard (if deployed)"
log_info "4. Verify data in monitoring tools"
log_info ""
log_info "For more information, see: $GOOSE_HOME/scripts/PRODUCTION_DEPLOYMENT.md"

