#!/bin/bash

# Monitor script for watching log and metrics files and triggering alerts
# This script can be run as a daemon or cron job to monitor script executions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logging-utils.sh"
source "$SCRIPT_DIR/alerting-utils.sh"

# Configuration
LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"  # Check every 60 seconds
RETENTION_DAYS="${RETENTION_DAYS:-30}"  # Keep logs for 30 days
ALERT_CONFIG_FILE="${ALERT_CONFIG_FILE:-$SCRIPT_DIR/alert-config.json}"
ROTATION_STATUS_FILE="${ROTATION_STATUS_FILE:-$LOG_DIR/.rotation-status.json}"
MISSED_ROTATION_THRESHOLD_HOURS="${GOOSE_LOG_MISSED_ROTATION_HOURS:-25}"

# Track processed files to avoid duplicate alerts
PROCESSED_FILES="${PROCESSED_FILES:-/tmp/goose-alerts-processed.txt}"
touch "$PROCESSED_FILES"

log_info "Starting alert monitor" "log_dir=$LOG_DIR" "interval=${MONITOR_INTERVAL}s"

# Function to check if file was already processed
is_file_processed() {
    local file="$1"
    grep -q "^$file$" "$PROCESSED_FILES" 2>/dev/null || return 1
}

# Function to mark file as processed
mark_file_processed() {
    local file="$1"
    echo "$file" >> "$PROCESSED_FILES"
}

# Function to monitor metrics files
monitor_metrics_files() {
    log_debug "Scanning metrics files in $LOG_DIR"
    
    find "$LOG_DIR" -name "*-metrics-*.json" -type f -mmin +1 2>/dev/null | while read -r metrics_file; do
        if is_file_processed "$metrics_file"; then
            continue
        fi
        
        log_debug "Analyzing metrics file: $metrics_file"
        analyze_metrics_and_alert "$metrics_file"
        mark_file_processed "$metrics_file"
    done
}

# Function to monitor log files for errors
monitor_log_files() {
    log_debug "Scanning log files in $LOG_DIR"
    
    find "$LOG_DIR" -name "*.jsonl" -type f -mmin +1 2>/dev/null | while read -r log_file; do
        if is_file_processed "$log_file"; then
            continue
        fi
        
        if ! command -v jq &> /dev/null; then
            log_warn "jq not available, skipping log file analysis"
            mark_file_processed "$log_file"
            continue
        fi
        
        # Count errors in log file
        local error_count=$(jq -r 'select(.level == "ERROR" or .level == "FATAL")' "$log_file" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
        
        if [[ $error_count -gt 0 ]]; then
            log_info "Found $error_count errors in $log_file"
            check_error_count "$log_file" "$error_count"
        fi
        
        mark_file_processed "$log_file"
    done
}

# Function to check for repeated failures
check_repeated_failures_across_scripts() {
    if ! command -v jq &> /dev/null; then
        return 0
    fi
    
    log_debug "Checking for repeated failures"
    
    # Group metrics files by script name and check for repeated failures
    declare -A script_failures
    
    find "$LOG_DIR" -name "*-metrics-*.json" -type f -mtime -1 2>/dev/null | while read -r metrics_file; do
        local script_name=$(jq -r '.script_name // "unknown"' "$metrics_file" 2>/dev/null || echo "unknown")
        local exit_code=$(jq -r '.exit_code // 0' "$metrics_file" 2>/dev/null || echo "0")
        
        if [[ $exit_code -ne 0 ]]; then
            script_failures["$script_name"]=$((${script_failures["$script_name"]:-0} + 1))
        fi
    done
    
    # Check each script for repeated failures
    for script_name in "${!script_failures[@]}"; do
        local failure_count="${script_failures[$script_name]}"
        if [[ $failure_count -ge $REPEATED_FAILURE_COUNT ]]; then
            check_repeated_failures "$script_name" "$failure_count"
        fi
    done
}

# Function to clean up old processed files list
cleanup_processed_files() {
    # Keep only files from last 7 days
    local cutoff_date=$(date -d "7 days ago" +%s 2>/dev/null || date -v-7d +%s 2>/dev/null || echo "0")
    
    if [[ $cutoff_date -eq 0 ]]; then
        # Fallback: keep last 1000 entries
        tail -n 1000 "$PROCESSED_FILES" > "${PROCESSED_FILES}.tmp" 2>/dev/null && \
            mv "${PROCESSED_FILES}.tmp" "$PROCESSED_FILES" 2>/dev/null || true
    fi
}

# Function to monitor rotation status
monitor_rotation_status() {
    if [[ ! -f "$ROTATION_STATUS_FILE" ]]; then
        log_debug "Rotation status file not found, skipping rotation monitoring"
        return 0
    fi
    
    if ! command -v jq &> /dev/null; then
        log_debug "jq not available, skipping rotation status monitoring"
        return 0
    fi
    
    log_debug "Checking rotation status"
    
    # Check if last rotation was successful
    local success=$(jq -r '.success // true' "$ROTATION_STATUS_FILE" 2>/dev/null || echo "true")
    if [[ "$success" != "true" ]]; then
        local error_message="Log rotation failed (check status file: $ROTATION_STATUS_FILE)"
        log_warn "$error_message"
        send_alert "$SEVERITY_HIGH" "rotation_failure" "$error_message" \
            "$(jq '{files_compressed, files_deleted, errors}' "$ROTATION_STATUS_FILE" 2>/dev/null || echo '{}')"
    fi
    
    # Check for missed rotations
    local last_rotation=$(jq -r '.last_rotation_time // 0' "$ROTATION_STATUS_FILE" 2>/dev/null || echo "0")
    if [[ $last_rotation -gt 0 ]]; then
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_rotation))
        local hours_diff=$((time_diff / 3600))
        
        if [[ $hours_diff -ge $MISSED_ROTATION_THRESHOLD_HOURS ]]; then
            local message="Missed log rotation: Last rotation was ${hours_diff} hours ago (threshold: ${MISSED_ROTATION_THRESHOLD_HOURS} hours)"
            log_warn "$message"
            send_alert "$SEVERITY_HIGH" "missed_rotation" "$message" \
                "{\"hours_since_last_rotation\": $hours_diff, \"threshold_hours\": $MISSED_ROTATION_THRESHOLD_HOURS}"
        fi
    fi
    
    # Check disk space from rotation status
    local disk_usage=$(jq -r '.disk_usage_percent // 0' "$ROTATION_STATUS_FILE" 2>/dev/null || echo "0")
    if [[ $disk_usage -ge 90 ]]; then
        local message="Critical disk space from rotation status: ${disk_usage}% used"
        log_warn "$message"
        send_alert "$SEVERITY_CRITICAL" "disk_space_critical" "$message" \
            "$(jq '{disk_usage_percent, available_disk_space_mb}' "$ROTATION_STATUS_FILE" 2>/dev/null || echo '{}')"
    elif [[ $disk_usage -ge 80 ]]; then
        local message="Warning: Disk space usage: ${disk_usage}% used"
        log_warn "$message"
        send_alert "$SEVERITY_HIGH" "disk_space_warning" "$message" \
            "$(jq '{disk_usage_percent, available_disk_space_mb}' "$ROTATION_STATUS_FILE" 2>/dev/null || echo '{}')"
    fi
}

# Function to clean up old log files
cleanup_old_logs() {
    log_debug "Cleaning up log files older than $RETENTION_DAYS days"
    find "$LOG_DIR" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
}

# Main monitoring loop
main_loop() {
    while true; do
        log_debug "Running monitoring cycle"
        
        # Monitor metrics files
        monitor_metrics_files
        
        # Monitor log files
        monitor_log_files
        
        # Check for repeated failures
        check_repeated_failures_across_scripts
        
        # Monitor rotation status
        monitor_rotation_status
        
        # Cleanup
        cleanup_processed_files
        cleanup_old_logs
        
        log_debug "Monitoring cycle complete, sleeping for ${MONITOR_INTERVAL}s"
        sleep "$MONITOR_INTERVAL"
    done
}

# Handle script termination
cleanup() {
    log_info "Alert monitor shutting down"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Run once or continuously
if [[ "${RUN_ONCE:-false}" == "true" ]]; then
    log_info "Running monitor once"
    monitor_metrics_files
    monitor_log_files
    check_repeated_failures_across_scripts
    monitor_rotation_status
    cleanup_processed_files
    cleanup_old_logs
else
    log_info "Starting continuous monitoring"
    main_loop
fi

