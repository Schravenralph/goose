#!/bin/bash

# Installation script for automated log rotation systemd timer
# Sets up systemd timer and service for log rotation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROTATE_SCRIPT="$SCRIPT_DIR/rotate-logs.sh"
SERVICE_TEMPLATE="$SCRIPT_DIR/goose-log-rotation.service"
TIMER_TEMPLATE="$SCRIPT_DIR/goose-log-rotation.timer"

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

# Default configuration
INSTALL_TYPE="${GOOSE_SYSTEMD_INSTALL_TYPE:-user}"  # user or system
TIMER_SCHEDULE="${GOOSE_SYSTEMD_SCHEDULE:-daily}"    # daily, weekly, or custom OnCalendar

# Function to check if systemd is available
check_systemd() {
    if ! command -v systemctl &> /dev/null; then
        print_error "systemctl not found. This script requires systemd."
        exit 1
    fi
    
    # Check if running under systemd
    if [[ ! -d /run/systemd/system ]] && [[ $EUID -ne 0 ]]; then
        # Try user systemd
        if ! systemctl --user list-units &> /dev/null; then
            print_error "systemd user session not available"
            exit 1
        fi
    fi
}

# Function to check if script exists and is executable
check_rotate_script() {
    if [[ ! -f "$ROTATE_SCRIPT" ]]; then
        print_error "Log rotation script not found: $ROTATE_SCRIPT"
        exit 1
    fi
    
    if [[ ! -x "$ROTATE_SCRIPT" ]]; then
        print_warning "Making rotation script executable..."
        chmod +x "$ROTATE_SCRIPT"
    fi
}

# Function to check if template files exist
check_templates() {
    if [[ ! -f "$SERVICE_TEMPLATE" ]]; then
        print_error "Service template not found: $SERVICE_TEMPLATE"
        exit 1
    fi
    
    if [[ ! -f "$TIMER_TEMPLATE" ]]; then
        print_error "Timer template not found: $TIMER_TEMPLATE"
        exit 1
    fi
}

# Function to get absolute path
get_absolute_path() {
    local path="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        readlink -f "$path" 2>/dev/null || python3 -c "import os; print(os.path.realpath('$path'))"
    else
        # Linux
        readlink -f "$path"
    fi
}

# Function to get systemd unit directory
get_systemd_unit_dir() {
    local install_type="$1"
    
    if [[ "$install_type" == "system" ]]; then
        echo "/etc/systemd/system"
    else
        # User systemd
        local user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        mkdir -p "$user_dir"
        echo "$user_dir"
    fi
}

# Function to create systemd service unit
create_service_unit() {
    local unit_dir="$1"
    local abs_rotate_script
    abs_rotate_script=$(get_absolute_path "$ROTATE_SCRIPT")
    local abs_script_dir
    abs_script_dir=$(get_absolute_path "$SCRIPT_DIR")
    local service_file="$unit_dir/goose-log-rotation.service"
    
    # Read template and replace placeholders
    sed -e "s|/path/to/goose/scripts/rotate-logs.sh|$abs_rotate_script|g" \
        -e "s|/path/to/goose/scripts|$abs_script_dir|g" \
        -e "s|Environment=\"LOG_DIR=/tmp/goose-logs\"|Environment=\"LOG_DIR=${LOG_DIR:-/tmp/goose-logs}\"|g" \
        -e "s|Environment=\"GOOSE_LOG_DETAILED_RETENTION_DAYS=7\"|Environment=\"GOOSE_LOG_DETAILED_RETENTION_DAYS=${GOOSE_LOG_DETAILED_RETENTION_DAYS:-7}\"|g" \
        -e "s|Environment=\"GOOSE_LOG_SUMMARY_RETENTION_DAYS=30\"|Environment=\"GOOSE_LOG_SUMMARY_RETENTION_DAYS=${GOOSE_LOG_SUMMARY_RETENTION_DAYS:-30}\"|g" \
        -e "s|Environment=\"GOOSE_LOG_ARCHIVE_RETENTION_DAYS=365\"|Environment=\"GOOSE_LOG_ARCHIVE_RETENTION_DAYS=${GOOSE_LOG_ARCHIVE_RETENTION_DAYS:-365}\"|g" \
        -e "s|Environment=\"GOOSE_LOG_COMPRESS_AFTER_DAYS=7\"|Environment=\"GOOSE_LOG_COMPRESS_AFTER_DAYS=${GOOSE_LOG_COMPRESS_AFTER_DAYS:-7}\"|g" \
        -e "s|Environment=\"GOOSE_LOG_MAX_SIZE_MB=100\"|Environment=\"GOOSE_LOG_MAX_SIZE_MB=${GOOSE_LOG_MAX_SIZE_MB:-100}\"|g" \
        "$SERVICE_TEMPLATE" > "$service_file"
    
    echo "$service_file"
}

# Function to create systemd timer unit
create_timer_unit() {
    local unit_dir="$1"
    local abs_script_dir
    abs_script_dir=$(get_absolute_path "$SCRIPT_DIR")
    local timer_file="$unit_dir/goose-log-rotation.timer"
    local on_calendar
    
    # Determine OnCalendar based on schedule
    case "$TIMER_SCHEDULE" in
        daily)
            on_calendar="daily"
            ;;
        weekly)
            on_calendar="weekly"
            ;;
        hourly)
            on_calendar="hourly"
            ;;
        *)
            # Custom schedule (should be in systemd OnCalendar format)
            on_calendar="$TIMER_SCHEDULE"
            ;;
    esac
    
    # Read template and replace placeholders
    # Replace OnCalendar line (match any OnCalendar value)
    sed -e "s|/path/to/goose/scripts|$abs_script_dir|g" \
        -e "s|^OnCalendar=.*|OnCalendar=$on_calendar|g" \
        "$TIMER_TEMPLATE" > "$timer_file"
    
    echo "$timer_file"
}

# Function to install user-level systemd units
install_user_systemd() {
    print_info "Installing user-level systemd units..."
    
    local unit_dir
    unit_dir=$(get_systemd_unit_dir "user")
    
    # Create service unit
    print_info "Creating service unit..."
    local service_file
    service_file=$(create_service_unit "$unit_dir")
    print_success "Service unit created: $service_file"
    
    # Create timer unit
    print_info "Creating timer unit..."
    local timer_file
    timer_file=$(create_timer_unit "$unit_dir")
    print_success "Timer unit created: $timer_file"
    
    # Reload systemd user daemon
    print_info "Reloading systemd user daemon..."
    systemctl --user daemon-reload
    
    # Enable timer
    print_info "Enabling timer..."
    systemctl --user enable goose-log-rotation.timer
    
    # Start timer
    print_info "Starting timer..."
    systemctl --user start goose-log-rotation.timer
    
    print_success "User-level systemd timer installed successfully"
    print_info "Service unit: $service_file"
    print_info "Timer unit: $timer_file"
}

# Function to install system-level systemd units
install_system_systemd() {
    print_info "Installing system-level systemd units..."
    
    # Check for root/sudo
    if [[ $EUID -ne 0 ]]; then
        print_error "System-level systemd installation requires root privileges"
        print_info "Please run with sudo: sudo $0"
        exit 1
    fi
    
    local unit_dir
    unit_dir=$(get_systemd_unit_dir "system")
    
    # Create service unit
    print_info "Creating service unit..."
    local service_file
    service_file=$(create_service_unit "$unit_dir")
    print_success "Service unit created: $service_file"
    
    # Create timer unit
    print_info "Creating timer unit..."
    local timer_file
    timer_file=$(create_timer_unit "$unit_dir")
    print_success "Timer unit created: $timer_file"
    
    # Reload systemd daemon
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload
    
    # Enable timer
    print_info "Enabling timer..."
    systemctl enable goose-log-rotation.timer
    
    # Start timer
    print_info "Starting timer..."
    systemctl start goose-log-rotation.timer
    
    print_success "System-level systemd timer installed successfully"
    print_info "Service unit: $service_file"
    print_info "Timer unit: $timer_file"
}

# Function to show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install automated log rotation systemd timer for Goose.

OPTIONS:
    -t, --type TYPE            Installation type: user or system (default: user)
    -s, --schedule SCHEDULE    Timer schedule: daily, weekly, hourly, or custom OnCalendar format (default: daily)
    -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
    GOOSE_SYSTEMD_INSTALL_TYPE Installation type: user or system
    GOOSE_SYSTEMD_SCHEDULE      Timer schedule (daily, weekly, hourly, or custom)
    LOG_DIR                     Log directory for rotation script
    GOOSE_LOG_*                 Log rotation configuration (see rotate-logs.sh)

EXAMPLES:
    # Install user-level systemd timer (daily at 2 AM)
    $0

    # Install system-level systemd timer (requires sudo)
    sudo $0 --type system

    # Install with weekly schedule
    $0 --schedule weekly

    # Install with custom schedule (daily at 3 AM)
    $0 --schedule "*-*-* 03:00:00"

SYSTEMD TIMER SCHEDULE FORMAT:
    daily                      Daily at 2:00 AM (default)
    weekly                     Weekly on Monday at 2:00 AM
    hourly                     Every hour
    "*-*-* 03:00:00"          Daily at 3:00 AM
    "Mon *-*-* 02:00:00"      Every Monday at 2:00 AM
    "*-*-01 02:00:00"         First day of month at 2:00 AM

See systemd.time(7) for more OnCalendar format options.

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            INSTALL_TYPE="$2"
            if [[ "$INSTALL_TYPE" != "user" && "$INSTALL_TYPE" != "system" ]]; then
                print_error "Invalid installation type: $INSTALL_TYPE (must be 'user' or 'system')"
                exit 1
            fi
            shift 2
            ;;
        -s|--schedule)
            TIMER_SCHEDULE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main installation
main() {
    print_info "Goose Log Rotation Systemd Timer Installation"
    print_info "=============================================="
    echo
    
    # Check prerequisites
    check_systemd
    check_rotate_script
    check_templates
    
    # Install based on type
    if [[ "$INSTALL_TYPE" == "system" ]]; then
        install_system_systemd
    else
        install_user_systemd
    fi
    
    echo
    print_success "Installation complete!"
    echo
    print_info "To check timer status:"
    if [[ "$INSTALL_TYPE" == "system" ]]; then
        print_info "  sudo systemctl status goose-log-rotation.timer"
        print_info "  sudo systemctl list-timers goose-log-rotation.timer"
    else
        print_info "  systemctl --user status goose-log-rotation.timer"
        print_info "  systemctl --user list-timers goose-log-rotation.timer"
    fi
    echo
    print_info "To view service logs:"
    if [[ "$INSTALL_TYPE" == "system" ]]; then
        print_info "  sudo journalctl -u goose-log-rotation.service"
    else
        print_info "  journalctl --user -u goose-log-rotation.service"
    fi
    echo
    print_info "To uninstall, run:"
    print_info "  $SCRIPT_DIR/uninstall-systemd-log-rotation.sh"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

