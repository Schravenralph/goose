#!/bin/bash

# Uninstallation script for automated log rotation systemd timer
# Removes systemd timer and service units

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
UNINSTALL_TYPE="${GOOSE_SYSTEMD_UNINSTALL_TYPE:-auto}"  # auto, user, or system

# Function to check if systemd is available
check_systemd() {
    if ! command -v systemctl &> /dev/null; then
        print_error "systemctl not found. This script requires systemd."
        exit 1
    fi
}

# Function to get systemd unit directory
get_systemd_unit_dir() {
    local install_type="$1"
    
    if [[ "$install_type" == "system" ]]; then
        echo "/etc/systemd/system"
    else
        # User systemd
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    fi
}

# Function to detect installation type
detect_install_type() {
    # Check system-level
    if [[ -f "/etc/systemd/system/goose-log-rotation.service" ]] || \
       [[ -f "/etc/systemd/system/goose-log-rotation.timer" ]]; then
        echo "system"
        return
    fi
    
    # Check user-level
    local user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    if [[ -f "$user_dir/goose-log-rotation.service" ]] || \
       [[ -f "$user_dir/goose-log-rotation.timer" ]]; then
        echo "user"
        return
    fi
    
    echo "none"
}

# Function to uninstall user-level systemd units
uninstall_user_systemd() {
    print_info "Uninstalling user-level systemd units..."
    
    # Stop and disable timer
    if systemctl --user list-units --all | grep -q "goose-log-rotation.timer"; then
        print_info "Stopping timer..."
        systemctl --user stop goose-log-rotation.timer 2>/dev/null || true
        
        print_info "Disabling timer..."
        systemctl --user disable goose-log-rotation.timer 2>/dev/null || true
    else
        print_warning "Timer not found in user systemd"
    fi
    
    # Stop service if running
    if systemctl --user list-units --all | grep -q "goose-log-rotation.service"; then
        print_info "Stopping service..."
        systemctl --user stop goose-log-rotation.service 2>/dev/null || true
    fi
    
    # Reload systemd user daemon
    print_info "Reloading systemd user daemon..."
    systemctl --user daemon-reload 2>/dev/null || true
    
    # Remove unit files
    local unit_dir
    unit_dir=$(get_systemd_unit_dir "user")
    
    local service_file="$unit_dir/goose-log-rotation.service"
    local timer_file="$unit_dir/goose-log-rotation.timer"
    
    if [[ -f "$service_file" ]]; then
        print_info "Removing service unit: $service_file"
        rm -f "$service_file"
        print_success "Service unit removed"
    else
        print_warning "Service unit not found: $service_file"
    fi
    
    if [[ -f "$timer_file" ]]; then
        print_info "Removing timer unit: $timer_file"
        rm -f "$timer_file"
        print_success "Timer unit removed"
    else
        print_warning "Timer unit not found: $timer_file"
    fi
    
    # Reload again after removing files
    systemctl --user daemon-reload 2>/dev/null || true
    
    print_success "User-level systemd units uninstalled"
}

# Function to uninstall system-level systemd units
uninstall_system_systemd() {
    print_info "Uninstalling system-level systemd units..."
    
    # Check for root/sudo
    if [[ $EUID -ne 0 ]]; then
        print_error "System-level systemd uninstallation requires root privileges"
        print_info "Please run with sudo: sudo $0"
        exit 1
    fi
    
    # Stop and disable timer
    if systemctl list-units --all | grep -q "goose-log-rotation.timer"; then
        print_info "Stopping timer..."
        systemctl stop goose-log-rotation.timer 2>/dev/null || true
        
        print_info "Disabling timer..."
        systemctl disable goose-log-rotation.timer 2>/dev/null || true
    else
        print_warning "Timer not found in system systemd"
    fi
    
    # Stop service if running
    if systemctl list-units --all | grep -q "goose-log-rotation.service"; then
        print_info "Stopping service..."
        systemctl stop goose-log-rotation.service 2>/dev/null || true
    fi
    
    # Reload systemd daemon
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload 2>/dev/null || true
    
    # Remove unit files
    local unit_dir
    unit_dir=$(get_systemd_unit_dir "system")
    
    local service_file="$unit_dir/goose-log-rotation.service"
    local timer_file="$unit_dir/goose-log-rotation.timer"
    
    if [[ -f "$service_file" ]]; then
        print_info "Removing service unit: $service_file"
        rm -f "$service_file"
        print_success "Service unit removed"
    else
        print_warning "Service unit not found: $service_file"
    fi
    
    if [[ -f "$timer_file" ]]; then
        print_info "Removing timer unit: $timer_file"
        rm -f "$timer_file"
        print_success "Timer unit removed"
    else
        print_warning "Timer unit not found: $timer_file"
    fi
    
    # Reload again after removing files
    systemctl daemon-reload 2>/dev/null || true
    
    print_success "System-level systemd units uninstalled"
}

# Function to show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Uninstall automated log rotation systemd timer for Goose.

OPTIONS:
    -t, --type TYPE            Uninstall type: auto, user, or system (default: auto)
                                - auto: Detect and remove from user or system systemd
                                - user: Remove only from user systemd
                                - system: Remove only from system systemd
    -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
    GOOSE_SYSTEMD_UNINSTALL_TYPE  Uninstall type: auto, user, or system

EXAMPLES:
    # Auto-detect and uninstall
    $0

    # Uninstall only user-level systemd units
    $0 --type user

    # Uninstall only system-level systemd units (requires sudo)
    sudo $0 --type system

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            UNINSTALL_TYPE="$2"
            if [[ "$UNINSTALL_TYPE" != "auto" && "$UNINSTALL_TYPE" != "user" && "$UNINSTALL_TYPE" != "system" ]]; then
                print_error "Invalid uninstall type: $UNINSTALL_TYPE (must be 'auto', 'user', or 'system')"
                exit 1
            fi
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

# Main uninstallation
main() {
    print_info "Goose Log Rotation Systemd Timer Uninstallation"
    print_info "==============================================="
    echo
    
    # Check prerequisites
    check_systemd
    
    # Detect installation type if auto
    local install_type="$UNINSTALL_TYPE"
    if [[ "$install_type" == "auto" ]]; then
        install_type=$(detect_install_type)
        if [[ "$install_type" == "none" ]]; then
            print_warning "No systemd timer installation detected. Nothing to uninstall."
            exit 0
        fi
        print_info "Detected installation type: $install_type"
    fi
    
    # Uninstall based on type
    if [[ "$install_type" == "system" ]]; then
        uninstall_system_systemd
    elif [[ "$install_type" == "user" ]]; then
        uninstall_user_systemd
    else
        # Try both if auto-detection found something
        uninstall_user_systemd
        if [[ $EUID -eq 0 ]]; then
            uninstall_system_systemd
        fi
    fi
    
    echo
    print_success "Uninstallation complete!"
    echo
    print_info "To verify timer removal:"
    if [[ "$install_type" == "system" ]] || [[ "$UNINSTALL_TYPE" == "auto" ]]; then
        print_info "  sudo systemctl list-timers (should not show goose-log-rotation.timer)"
    fi
    if [[ "$install_type" == "user" ]] || [[ "$UNINSTALL_TYPE" == "auto" ]]; then
        print_info "  systemctl --user list-timers (should not show goose-log-rotation.timer)"
    fi
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

