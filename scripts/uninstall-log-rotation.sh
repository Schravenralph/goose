#!/bin/bash

# Uninstallation script for automated log rotation
# Removes all automation configurations (cron and systemd)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

DRY_RUN="${GOOSE_ROTATION_DRY_RUN:-false}"

# Function to uninstall cron
uninstall_cron() {
    local install_type="${1:-user}"
    
    print_info "Uninstalling cron-based log rotation..."
    
    if [[ "$install_type" == "system" ]]; then
        if [[ $EUID -ne 0 ]]; then
            print_error "System-level uninstallation requires root privileges"
            print_info "Please run with sudo: sudo $0"
            exit 1
        fi
        
        local cron_file="/etc/cron.d/goose-log-rotation"
        if [[ -f "$cron_file" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would remove: $cron_file"
            else
                rm -f "$cron_file"
                print_success "Removed system cron file: $cron_file"
            fi
        else
            print_info "System cron file not found: $cron_file"
        fi
    else
        local cron_comment="# Goose log rotation cron job"
        if crontab -l 2>/dev/null | grep -q "$cron_comment"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would remove cron job from user crontab"
            else
                crontab -l 2>/dev/null | grep -v "$cron_comment" | grep -v "cron-rotate-logs-wrapper.sh" | crontab - || true
                print_success "Removed cron job from user crontab"
            fi
        else
            print_info "Cron job not found in user crontab"
        fi
    fi
    
    # Remove wrapper script
    local wrapper_file="$SCRIPT_DIR/cron-rotate-logs-wrapper.sh"
    if [[ -f "$wrapper_file" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY RUN] Would remove: $wrapper_file"
        else
            rm -f "$wrapper_file"
            print_success "Removed wrapper script: $wrapper_file"
        fi
    fi
}

# Function to uninstall systemd
uninstall_systemd() {
    local install_type="${1:-user}"
    
    print_info "Uninstalling systemd timer-based log rotation..."
    
    if [[ "$install_type" == "system" ]]; then
        if [[ $EUID -ne 0 ]]; then
            print_error "System-level uninstallation requires root privileges"
            print_info "Please run with sudo: sudo $0"
            exit 1
        fi
        
        local service_file="/etc/systemd/system/goose-log-rotation.service"
        local timer_file="/etc/systemd/system/goose-log-rotation.timer"
        
        if systemctl is-enabled goose-log-rotation.timer &> /dev/null; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would stop and disable systemd timer"
            else
                systemctl stop goose-log-rotation.timer 2>/dev/null || true
                systemctl disable goose-log-rotation.timer 2>/dev/null || true
                print_success "Stopped and disabled systemd timer"
            fi
        fi
        
        if [[ -f "$service_file" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would remove: $service_file"
            else
                rm -f "$service_file"
                print_success "Removed service file: $service_file"
            fi
        fi
        
        if [[ -f "$timer_file" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would remove: $timer_file"
            else
                rm -f "$timer_file"
                print_success "Removed timer file: $timer_file"
            fi
        fi
        
        if [[ "$DRY_RUN" != "true" ]]; then
            systemctl daemon-reload 2>/dev/null || true
        fi
    else
        local service_file="$HOME/.config/systemd/user/goose-log-rotation.service"
        local timer_file="$HOME/.config/systemd/user/goose-log-rotation.timer"
        
        if systemctl --user is-enabled goose-log-rotation.timer &> /dev/null 2>&1; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would stop and disable user systemd timer"
            else
                systemctl --user stop goose-log-rotation.timer 2>/dev/null || true
                systemctl --user disable goose-log-rotation.timer 2>/dev/null || true
                print_success "Stopped and disabled user systemd timer"
            fi
        fi
        
        if [[ -f "$service_file" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would remove: $service_file"
            else
                rm -f "$service_file"
                print_success "Removed service file: $service_file"
            fi
        fi
        
        if [[ -f "$timer_file" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would remove: $timer_file"
            else
                rm -f "$timer_file"
                print_success "Removed timer file: $timer_file"
            fi
        fi
        
        if [[ "$DRY_RUN" != "true" ]]; then
            systemctl --user daemon-reload 2>/dev/null || true
        fi
    fi
}

# Function to read configuration
read_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    if command -v jq &> /dev/null; then
        METHOD=$(jq -r '.method // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
        INSTALL_TYPE=$(jq -r '.install_type // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        # Fallback: simple grep parsing
        METHOD=$(grep -o '"method"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"method"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
        INSTALL_TYPE=$(grep -o '"install_type"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"install_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
    fi
    
    return 0
}

# Function to detect installed methods
detect_installed_methods() {
    local methods=()
    
    # Check for cron
    if crontab -l 2>/dev/null | grep -q "Goose log rotation cron job" || \
       [[ -f "/etc/cron.d/goose-log-rotation" ]]; then
        methods+=("cron")
    fi
    
    # Check for systemd
    if systemctl list-units --type=timer --all 2>/dev/null | grep -q "goose-log-rotation.timer" || \
       systemctl --user list-units --type=timer --all 2>/dev/null | grep -q "goose-log-rotation.timer"; then
        methods+=("systemd")
    fi
    
    echo "${methods[@]}"
}

# Function to show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Uninstall automated log rotation for Goose (removes cron and systemd configurations).

OPTIONS:
    -m, --method METHOD        Uninstall specific method: cron or systemd (uninstalls all if not specified)
    -t, --type TYPE            Installation type: user or system (default: user)
    -d, --dry-run              Dry run mode (show what would be removed without making changes)
    -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
    GOOSE_ROTATION_DRY_RUN     Set to "true" for dry run mode

EXAMPLES:
    # Uninstall all rotation methods
    $0

    # Uninstall only cron
    $0 --method cron

    # Uninstall system-level installation (requires sudo)
    sudo $0 --type system

    # Dry run to see what would be removed
    $0 --dry-run

EOF
}

# Parse command line arguments
METHOD=""
INSTALL_TYPE="user"
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--method)
            METHOD="$2"
            if [[ "$METHOD" != "cron" && "$METHOD" != "systemd" ]]; then
                print_error "Invalid method: $METHOD (must be 'cron' or 'systemd')"
                exit 1
            fi
            shift 2
            ;;
        -t|--type)
            INSTALL_TYPE="$2"
            if [[ "$INSTALL_TYPE" != "user" && "$INSTALL_TYPE" != "system" ]]; then
                print_error "Invalid installation type: $INSTALL_TYPE (must be 'user' or 'system')"
                exit 1
            fi
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN="true"
            shift
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
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - No changes will be made"
        echo
    fi
    
    print_info "Goose Log Rotation Uninstallation"
    print_info "==================================="
    echo
    
    # Try to read configuration
    local config_method=""
    local config_install_type=""
    if read_config; then
        config_method="$METHOD"
        config_install_type="$INSTALL_TYPE"
        print_info "Found configuration: method=$config_method, type=$config_install_type"
    fi
    
    # Use config values if not specified
    if [[ -z "$METHOD" ]]; then
        METHOD="$config_method"
    fi
    if [[ -z "$INSTALL_TYPE" || "$INSTALL_TYPE" == "user" ]]; then
        INSTALL_TYPE="${config_install_type:-user}"
    fi
    
    # Detect installed methods if method not specified
    if [[ -z "$METHOD" ]]; then
        local installed_methods
        installed_methods=($(detect_installed_methods))
        
        if [[ ${#installed_methods[@]} -eq 0 ]]; then
            print_warning "No log rotation installation detected"
            print_info "Checked for:"
            print_info "  - Cron jobs (user and system)"
            print_info "  - Systemd timers (user and system)"
            exit 0
        fi
        
        print_info "Detected installed methods: ${installed_methods[*]}"
        
        # Uninstall all detected methods
        for method in "${installed_methods[@]}"; do
            if [[ "$method" == "cron" ]]; then
                uninstall_cron "$INSTALL_TYPE"
            elif [[ "$method" == "systemd" ]]; then
                uninstall_systemd "$INSTALL_TYPE"
            fi
        done
    else
        # Uninstall specific method
        if [[ "$METHOD" == "cron" ]]; then
            uninstall_cron "$INSTALL_TYPE"
        elif [[ "$METHOD" == "systemd" ]]; then
            uninstall_systemd "$INSTALL_TYPE"
        fi
    fi
    
    # Remove configuration file
    if [[ -f "$CONFIG_FILE" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY RUN] Would remove: $CONFIG_FILE"
        else
            rm -f "$CONFIG_FILE"
            print_success "Removed configuration file: $CONFIG_FILE"
        fi
    fi
    
    echo
    print_success "Uninstallation complete!"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

