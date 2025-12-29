#!/bin/bash

# Management script for automated log rotation
# Provides status checking, enable/disable, testing, and log viewing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROTATE_SCRIPT="$SCRIPT_DIR/rotate-logs.sh"
CONFIG_DIR="${GOOSE_LOG_ROTATION_CONFIG_DIR:-$HOME/.config/goose/log-rotation}"
CONFIG_FILE="$CONFIG_DIR/rotation-config.json"

# Source logging utilities if available
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to read configuration
read_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    if command -v jq &> /dev/null; then
        METHOD=$(jq -r '.method // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
        SCHEDULE=$(jq -r '.schedule // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
        INSTALL_TYPE=$(jq -r '.install_type // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
        INSTALLED_AT=$(jq -r '.installed_at // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        # Fallback: simple grep parsing
        METHOD=$(grep -o '"method"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"method"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
        SCHEDULE=$(grep -o '"schedule"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"schedule"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
        INSTALL_TYPE=$(grep -o '"install_type"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"install_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
        INSTALLED_AT=$(grep -o '"installed_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"installed_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
    fi
    
    return 0
}

# Function to check cron status
check_cron_status() {
    local install_type="${1:-user}"
    local status="not_installed"
    local schedule=""
    local last_run="unknown"
    
    if [[ "$install_type" == "system" ]]; then
        if [[ -f "/etc/cron.d/goose-log-rotation" ]]; then
            status="installed"
            schedule=$(grep -v "^#" "/etc/cron.d/goose-log-rotation" 2>/dev/null | grep -v "^$" | awk '{print $1, $2, $3, $4, $5}' | head -1 || echo "")
        fi
    else
        if crontab -l 2>/dev/null | grep -q "Goose log rotation cron job"; then
            status="installed"
            schedule=$(crontab -l 2>/dev/null | grep "Goose log rotation cron job" | awk '{print $1, $2, $3, $4, $5}' || echo "")
        fi
    fi
    
    # Check for last run in log file
    local log_file="${GOOSE_ROTATION_LOG_DIR:-/tmp/goose-logs}/cron-rotation.log"
    if [[ -f "$log_file" ]]; then
        last_run=$(stat -c "%y" "$log_file" 2>/dev/null || stat -f "%Sm" "$log_file" 2>/dev/null || echo "unknown")
    fi
    
    echo "$status|$schedule|$last_run"
}

# Function to check systemd status
check_systemd_status() {
    local install_type="${1:-user}"
    local status="not_installed"
    local schedule=""
    local last_run="unknown"
    local next_run="unknown"
    
    if [[ "$install_type" == "system" ]]; then
        if systemctl list-units --type=timer --all 2>/dev/null | grep -q "goose-log-rotation.timer"; then
            if systemctl is-enabled goose-log-rotation.timer &> /dev/null; then
                status="enabled"
            else
                status="installed"
            fi
            
            if systemctl is-active goose-log-rotation.timer &> /dev/null; then
                status="${status}_active"
            fi
            
            # Get schedule from timer file
            if [[ -f "/etc/systemd/system/goose-log-rotation.timer" ]]; then
                schedule=$(grep "^OnCalendar=" "/etc/systemd/system/goose-log-rotation.timer" 2>/dev/null | cut -d= -f2 || echo "")
            fi
            
            # Get last and next run times
            if systemctl is-active goose-log-rotation.timer &> /dev/null; then
                last_run=$(systemctl show goose-log-rotation.timer -p LastTriggerUSec --value 2>/dev/null || echo "unknown")
                next_run=$(systemctl list-timers goose-log-rotation.timer --no-pager --no-legend 2>/dev/null | awk '{print $1, $2}' || echo "unknown")
            fi
        fi
    else
        if systemctl --user list-units --type=timer --all 2>/dev/null | grep -q "goose-log-rotation.timer"; then
            if systemctl --user is-enabled goose-log-rotation.timer &> /dev/null; then
                status="enabled"
            else
                status="installed"
            fi
            
            if systemctl --user is-active goose-log-rotation.timer &> /dev/null; then
                status="${status}_active"
            fi
            
            # Get schedule from timer file
            if [[ -f "$HOME/.config/systemd/user/goose-log-rotation.timer" ]]; then
                schedule=$(grep "^OnCalendar=" "$HOME/.config/systemd/user/goose-log-rotation.timer" 2>/dev/null | cut -d= -f2 || echo "")
            fi
            
            # Get last and next run times
            if systemctl --user is-active goose-log-rotation.timer &> /dev/null; then
                last_run=$(systemctl --user show goose-log-rotation.timer -p LastTriggerUSec --value 2>/dev/null || echo "unknown")
                next_run=$(systemctl --user list-timers goose-log-rotation.timer --no-pager --no-legend 2>/dev/null | awk '{print $1, $2}' || echo "unknown")
            fi
        fi
    fi
    
    echo "$status|$schedule|$last_run|$next_run"
}

# Function to show status
show_status() {
    print_info "Goose Log Rotation Status"
    print_info "=========================="
    echo
    
    # Read configuration
    local config_method=""
    local config_install_type="user"
    if read_config; then
        config_method="$METHOD"
        config_install_type="${INSTALL_TYPE:-user}"
        print_info "Configuration file: $CONFIG_FILE"
        print_info "Method: $config_method"
        print_info "Install type: $config_install_type"
        if [[ -n "$INSTALLED_AT" ]]; then
            print_info "Installed at: $INSTALLED_AT"
        fi
        echo
    else
        print_warning "No configuration file found: $CONFIG_FILE"
        print_info "Checking for installed methods..."
        echo
    fi
    
    # Check cron status
    print_info "Cron Status:"
    local cron_status_info
    cron_status_info=$(check_cron_status "$config_install_type")
    IFS='|' read -r cron_status cron_schedule cron_last_run <<< "$cron_status_info"
    
    if [[ "$cron_status" == "installed" ]]; then
        print_success "  Status: Installed"
        if [[ -n "$cron_schedule" ]]; then
            print_info "  Schedule: $cron_schedule"
        fi
        print_info "  Last run: $cron_last_run"
    else
        print_warning "  Status: Not installed"
    fi
    echo
    
    # Check systemd status
    print_info "Systemd Timer Status:"
    local systemd_status_info
    systemd_status_info=$(check_systemd_status "$config_install_type")
    IFS='|' read -r systemd_status systemd_schedule systemd_last_run systemd_next_run <<< "$systemd_status_info"
    
    if [[ "$systemd_status" != "not_installed" ]]; then
        if [[ "$systemd_status" == *"enabled"* ]] && [[ "$systemd_status" == *"active"* ]]; then
            print_success "  Status: Enabled and active"
        elif [[ "$systemd_status" == *"enabled"* ]]; then
            print_warning "  Status: Enabled but not active"
        else
            print_warning "  Status: Installed but not enabled"
        fi
        if [[ -n "$systemd_schedule" ]]; then
            print_info "  Schedule: OnCalendar=$systemd_schedule"
        fi
        print_info "  Last run: $systemd_last_run"
        if [[ "$systemd_next_run" != "unknown" ]]; then
            print_info "  Next run: $systemd_next_run"
        fi
    else
        print_warning "  Status: Not installed"
    fi
    echo
}

# Function to enable rotation
enable_rotation() {
    local method="${1:-}"
    local install_type="${2:-user}"
    
    if [[ -z "$method" ]]; then
        if read_config; then
            method="$METHOD"
            install_type="${INSTALL_TYPE:-user}"
        else
            print_error "No method specified and no configuration found"
            print_info "Please specify method: --method cron or --method systemd"
            exit 1
        fi
    fi
    
    print_info "Enabling log rotation (method: $method, type: $install_type)..."
    
    if [[ "$method" == "systemd" ]]; then
        if [[ "$install_type" == "system" ]]; then
            if [[ $EUID -ne 0 ]]; then
                print_error "System-level operations require root privileges"
                exit 1
            fi
            systemctl enable goose-log-rotation.timer
            systemctl start goose-log-rotation.timer
            print_success "Systemd timer enabled and started"
        else
            systemctl --user enable goose-log-rotation.timer
            systemctl --user start goose-log-rotation.timer
            print_success "User systemd timer enabled and started"
        fi
    elif [[ "$method" == "cron" ]]; then
        print_info "Cron jobs are always enabled when installed"
        print_info "To disable, use: $0 disable"
    else
        print_error "Unknown method: $method"
        exit 1
    fi
}

# Function to disable rotation
disable_rotation() {
    local method="${1:-}"
    local install_type="${2:-user}"
    
    if [[ -z "$method" ]]; then
        if read_config; then
            method="$METHOD"
            install_type="${INSTALL_TYPE:-user}"
        else
            print_error "No method specified and no configuration found"
            exit 1
        fi
    fi
    
    print_info "Disabling log rotation (method: $method, type: $install_type)..."
    
    if [[ "$method" == "systemd" ]]; then
        if [[ "$install_type" == "system" ]]; then
            if [[ $EUID -ne 0 ]]; then
                print_error "System-level operations require root privileges"
                exit 1
            fi
            systemctl stop goose-log-rotation.timer
            systemctl disable goose-log-rotation.timer
            print_success "Systemd timer stopped and disabled"
        else
            systemctl --user stop goose-log-rotation.timer
            systemctl --user disable goose-log-rotation.timer
            print_success "User systemd timer stopped and disabled"
        fi
    elif [[ "$method" == "cron" ]]; then
        print_warning "Cron jobs cannot be easily disabled without uninstalling"
        print_info "To remove cron job, use: $SCRIPT_DIR/uninstall-log-rotation.sh --method cron"
    else
        print_error "Unknown method: $method"
        exit 1
    fi
}

# Function to test rotation
test_rotation() {
    print_info "Testing log rotation..."
    
    if [[ ! -f "$ROTATE_SCRIPT" ]]; then
        print_error "Rotation script not found: $ROTATE_SCRIPT"
        exit 1
    fi
    
    if [[ ! -x "$ROTATE_SCRIPT" ]]; then
        print_error "Rotation script is not executable: $ROTATE_SCRIPT"
        exit 1
    fi
    
    print_info "Running: $ROTATE_SCRIPT"
    echo
    
    if "$ROTATE_SCRIPT"; then
        echo
        print_success "Rotation test completed successfully"
    else
        echo
        print_error "Rotation test failed with exit code $?"
        exit 1
    fi
}

# Function to show logs
show_logs() {
    local lines="${1:-50}"
    local log_file="${GOOSE_ROTATION_LOG_DIR:-/tmp/goose-logs}/cron-rotation.log"
    
    if [[ -f "$log_file" ]]; then
        print_info "Showing last $lines lines of rotation log: $log_file"
        echo
        tail -n "$lines" "$log_file"
    else
        print_warning "Log file not found: $log_file"
        print_info "Rotation may not have run yet, or logs are stored elsewhere"
        
        # Check for systemd journal logs
        if systemctl list-units --type=service --all 2>/dev/null | grep -q "goose-log-rotation.service"; then
            print_info "Checking systemd journal for rotation logs..."
            echo
            if systemctl is-active goose-log-rotation.service &> /dev/null || \
               systemctl --user is-active goose-log-rotation.service &> /dev/null; then
                journalctl -u goose-log-rotation.service -n "$lines" --no-pager 2>/dev/null || \
                journalctl --user -u goose-log-rotation.service -n "$lines" --no-pager 2>/dev/null || \
                print_warning "Could not access systemd journal"
            fi
        fi
    fi
}

# Function to show usage
show_usage() {
    cat <<EOF
Usage: $0 COMMAND [OPTIONS]

Manage automated log rotation for Goose.

COMMANDS:
    status                  Show rotation status and configuration
    enable                  Enable rotation (systemd only, cron is always enabled)
    disable                 Disable rotation (systemd only)
    test                    Test rotation by running it manually
    logs [LINES]            Show rotation logs (default: 50 lines)

OPTIONS:
    -m, --method METHOD     Specify method: cron or systemd
    -t, --type TYPE         Installation type: user or system (default: user)
    -h, --help              Show this help message

EXAMPLES:
    # Show status
    $0 status

    # Enable systemd timer
    $0 enable --method systemd

    # Disable systemd timer
    $0 disable --method systemd

    # Test rotation manually
    $0 test

    # Show last 100 lines of logs
    $0 logs 100

EOF
}

# Main
main() {
    local command="${1:-status}"
    
    case "$command" in
        status)
            show_status
            ;;
        enable)
            shift
            local method=""
            local install_type="user"
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -m|--method)
                        method="$2"
                        shift 2
                        ;;
                    -t|--type)
                        install_type="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            enable_rotation "$method" "$install_type"
            ;;
        disable)
            shift
            local method=""
            local install_type="user"
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -m|--method)
                        method="$2"
                        shift 2
                        ;;
                    -t|--type)
                        install_type="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            disable_rotation "$method" "$install_type"
            ;;
        test)
            test_rotation
            ;;
        logs)
            shift
            local lines="${1:-50}"
            show_logs "$lines"
            ;;
        -h|--help|help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        main "status"
    else
        main "$@"
    fi
fi

