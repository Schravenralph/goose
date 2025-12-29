#!/bin/bash

# Uninstallation script for automated log rotation cron job
# Removes cron job and wrapper script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SCRIPT="$SCRIPT_DIR/cron-rotate-logs-wrapper.sh"

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
UNINSTALL_TYPE="${GOOSE_CRON_UNINSTALL_TYPE:-auto}"  # auto, user, or system

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

# Function to detect installation type
detect_install_type() {
    local abs_wrapper_script
    abs_wrapper_script=$(get_absolute_path "$WRAPPER_SCRIPT" 2>/dev/null || echo "")
    
    # Check system-level cron
    if [[ -f "/etc/cron.d/goose-log-rotation" ]]; then
        if [[ -n "$abs_wrapper_script" ]] && grep -q "$abs_wrapper_script" /etc/cron.d/goose-log-rotation 2>/dev/null; then
            echo "system"
            return
        fi
    fi
    
    # Check user-level cron
    if crontab -l 2>/dev/null | grep -q "goose-log-rotation\|cron-rotate-logs-wrapper" || \
       ([[ -n "$abs_wrapper_script" ]] && crontab -l 2>/dev/null | grep -q "$abs_wrapper_script"); then
        echo "user"
        return
    fi
    
    echo "none"
}

# Function to uninstall user-level cron
uninstall_user_cron() {
    print_info "Uninstalling user-level cron job..."
    
    local abs_wrapper_script
    abs_wrapper_script=$(get_absolute_path "$WRAPPER_SCRIPT" 2>/dev/null || echo "")
    local cron_comment="# Goose log rotation cron job"
    
    # Get current crontab
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || echo "")
    
    if [[ -z "$current_crontab" ]]; then
        print_warning "No crontab found. Nothing to uninstall."
        return 0
    fi
    
    # Check if cron job exists
    if echo "$current_crontab" | grep -q "$cron_comment"; then
        # Remove cron job entries
        echo "$current_crontab" | grep -v "$cron_comment" | grep -v "$abs_wrapper_script" | crontab -
        print_success "User-level cron job removed"
    elif [[ -n "$abs_wrapper_script" ]] && echo "$current_crontab" | grep -q "$abs_wrapper_script"; then
        # Remove by wrapper script path
        echo "$current_crontab" | grep -v "$abs_wrapper_script" | crontab -
        print_success "User-level cron job removed"
    else
        print_warning "No matching cron job found in user crontab"
    fi
}

# Function to uninstall system-level cron
uninstall_system_cron() {
    print_info "Uninstalling system-level cron job..."
    
    # Check for root/sudo
    if [[ $EUID -ne 0 ]]; then
        print_error "System-level cron uninstallation requires root privileges"
        print_info "Please run with sudo: sudo $0"
        exit 1
    fi
    
    local cron_file="/etc/cron.d/goose-log-rotation"
    
    if [[ -f "$cron_file" ]]; then
        rm -f "$cron_file"
        print_success "System-level cron file removed: $cron_file"
    else
        print_warning "System-level cron file not found: $cron_file"
    fi
}

# Function to remove wrapper script
remove_wrapper_script() {
    if [[ -f "$WRAPPER_SCRIPT" ]]; then
        print_info "Removing wrapper script: $WRAPPER_SCRIPT"
        rm -f "$WRAPPER_SCRIPT"
        print_success "Wrapper script removed"
    else
        print_info "Wrapper script not found: $WRAPPER_SCRIPT (may have been removed already)"
    fi
}

# Function to show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Uninstall automated log rotation cron job for Goose.

OPTIONS:
    -t, --type TYPE            Uninstall type: auto, user, or system (default: auto)
                                - auto: Detect and remove from user or system cron
                                - user: Remove only from user crontab
                                - system: Remove only from system cron
    -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
    GOOSE_CRON_UNINSTALL_TYPE  Uninstall type: auto, user, or system

EXAMPLES:
    # Auto-detect and uninstall
    $0

    # Uninstall only user-level cron
    $0 --type user

    # Uninstall only system-level cron (requires sudo)
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
    print_info "Goose Log Rotation Cron Uninstallation"
    print_info "======================================"
    echo
    
    # Detect installation type if auto
    local install_type="$UNINSTALL_TYPE"
    if [[ "$install_type" == "auto" ]]; then
        install_type=$(detect_install_type)
        if [[ "$install_type" == "none" ]]; then
            print_warning "No cron job installation detected. Nothing to uninstall."
            remove_wrapper_script
            exit 0
        fi
        print_info "Detected installation type: $install_type"
    fi
    
    # Uninstall based on type
    if [[ "$install_type" == "system" ]]; then
        uninstall_system_cron
    elif [[ "$install_type" == "user" ]]; then
        uninstall_user_cron
    else
        # Try both if auto-detection found something
        uninstall_user_cron
        if [[ $EUID -eq 0 ]]; then
            uninstall_system_cron
        fi
    fi
    
    # Remove wrapper script
    remove_wrapper_script
    
    echo
    print_success "Uninstallation complete!"
    echo
    print_info "To verify cron job removal:"
    if [[ "$install_type" == "system" ]] || [[ "$UNINSTALL_TYPE" == "auto" ]]; then
        print_info "  sudo cat /etc/cron.d/goose-log-rotation (should not exist)"
    fi
    if [[ "$install_type" == "user" ]] || [[ "$UNINSTALL_TYPE" == "auto" ]]; then
        print_info "  crontab -l (should not contain goose log rotation entries)"
    fi
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
