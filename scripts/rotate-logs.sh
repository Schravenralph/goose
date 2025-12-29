#!/bin/bash

# Log rotation and retention script for Goose logs
# Handles both bash script logs (/tmp/goose-logs/) and Rust logs (state_dir/logs/)

set -euo pipefail

# Source logging utilities if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

# Source alerting utilities if available
if [[ -f "$SCRIPT_DIR/alerting-utils.sh" ]]; then
    source "$SCRIPT_DIR/alerting-utils.sh"
fi

# Configuration (can be overridden via environment variables)
DETAILED_RETENTION_DAYS="${GOOSE_LOG_DETAILED_RETENTION_DAYS:-7}"
SUMMARY_RETENTION_DAYS="${GOOSE_LOG_SUMMARY_RETENTION_DAYS:-30}"
ARCHIVE_RETENTION_DAYS="${GOOSE_LOG_ARCHIVE_RETENTION_DAYS:-365}"
COMPRESS_AFTER_DAYS="${GOOSE_LOG_COMPRESS_AFTER_DAYS:-7}"
MAX_LOG_SIZE_MB="${GOOSE_LOG_MAX_SIZE_MB:-100}"

# Directories
BASH_LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
ARCHIVE_DIR="${GOOSE_LOG_ARCHIVE_DIR:-$BASH_LOG_DIR/archive}"

# Status file for rotation monitoring
ROTATION_STATUS_FILE="${ROTATION_STATUS_FILE:-$BASH_LOG_DIR/.rotation-status.json}"

# Disk space thresholds (can be overridden via environment variables)
DISK_SPACE_WARNING_THRESHOLD="${GOOSE_LOG_DISK_SPACE_WARNING:-80}"  # Percentage
DISK_SPACE_CRITICAL_THRESHOLD="${GOOSE_LOG_DISK_SPACE_CRITICAL:-90}"  # Percentage

# Missed rotation detection (default: 25 hours for daily rotation)
MISSED_ROTATION_THRESHOLD_HOURS="${GOOSE_LOG_MISSED_ROTATION_HOURS:-25}"

# Initialize metrics counters
ROTATION_FILES_COMPRESSED=0
ROTATION_FILES_DELETED=0
ROTATION_FILES_ARCHIVED=0
ROTATION_SPACE_FREED=0
ROTATION_START_TIME=$(date +%s)
ROTATION_SUCCESS=true
ROTATION_ERRORS=()

# Function to get disk space usage percentage
get_disk_space_usage() {
    local path="${1:-$BASH_LOG_DIR}"
    local mount_point
    
    # Get mount point for the path
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mount_point=$(df -P "$path" 2>/dev/null | tail -1 | awk '{print $NF}')
    else
        mount_point=$(df -P "$path" 2>/dev/null | tail -1 | awk '{print $NF}')
    fi
    
    # Get disk usage percentage
    if [[ "$OSTYPE" == "darwin"* ]]; then
        df -P "$path" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//'
    else
        df -P "$path" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//'
    fi
}

# Function to get available disk space in bytes
get_available_disk_space() {
    local path="${1:-$BASH_LOG_DIR}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        df -P "$path" 2>/dev/null | tail -1 | awk '{print $4 * 1024}'
    else
        df -P "$path" 2>/dev/null | tail -1 | awk '{print $4 * 1024}'
    fi
}

# Function to check disk space and alert if needed
check_disk_space() {
    local path="${1:-$BASH_LOG_DIR}"
    local usage_percent=$(get_disk_space_usage "$path")
    local available_bytes=$(get_available_disk_space "$path")
    local available_mb=$((available_bytes / 1024 / 1024))
    
    if command -v record_metric &> /dev/null; then
        record_metric "disk_space_usage_percent" "$usage_percent" "path=$path"
        record_metric "disk_space_available_mb" "$available_mb" "path=$path"
    fi
    
    if [[ $usage_percent -ge $DISK_SPACE_CRITICAL_THRESHOLD ]]; then
        local message="Critical disk space usage: ${usage_percent}% used (${available_mb}MB available) on $path"
        if command -v log_error &> /dev/null; then
            log_error "$message"
        else
            echo "ERROR: $message" >&2
        fi
        ROTATION_ERRORS+=("$message")
        
        if command -v send_alert &> /dev/null; then
            send_alert "$SEVERITY_CRITICAL" "disk_space_critical" "$message" \
                "{\"usage_percent\": $usage_percent, \"available_mb\": $available_mb, \"path\": \"$path\"}"
        fi
        return 2
    elif [[ $usage_percent -ge $DISK_SPACE_WARNING_THRESHOLD ]]; then
        local message="Warning: Disk space usage: ${usage_percent}% used (${available_mb}MB available) on $path"
        if command -v log_warn &> /dev/null; then
            log_warn "$message"
        else
            echo "WARNING: $message" >&2
        fi
        
        if command -v send_alert &> /dev/null; then
            send_alert "$SEVERITY_HIGH" "disk_space_warning" "$message" \
                "{\"usage_percent\": $usage_percent, \"available_mb\": $available_mb, \"path\": \"$path\"}"
        fi
        return 1
    fi
    
    if command -v log_debug &> /dev/null; then
        log_debug "Disk space check: ${usage_percent}% used (${available_mb}MB available) on $path"
    fi
    return 0
}

# Function to check for missed rotations
check_missed_rotation() {
    local status_file="$ROTATION_STATUS_FILE"
    local current_time=$(date +%s)
    local last_rotation_time=0
    
    if [[ -f "$status_file" ]] && command -v jq &> /dev/null; then
        last_rotation_time=$(jq -r '.last_rotation_time // 0' "$status_file" 2>/dev/null || echo "0")
    elif [[ -f "$status_file" ]]; then
        # Fallback: try to extract timestamp from file
        last_rotation_time=$(grep -o '"last_rotation_time":[0-9]*' "$status_file" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
    fi
    
    if [[ $last_rotation_time -gt 0 ]]; then
        local time_diff=$((current_time - last_rotation_time))
        local hours_diff=$((time_diff / 3600))
        
        if [[ $hours_diff -ge $MISSED_ROTATION_THRESHOLD_HOURS ]]; then
            local message="Missed log rotation detected: Last rotation was ${hours_diff} hours ago (threshold: ${MISSED_ROTATION_THRESHOLD_HOURS} hours)"
            if command -v log_error &> /dev/null; then
                log_error "$message"
            else
                echo "ERROR: $message" >&2
            fi
            ROTATION_ERRORS+=("$message")
            
            if command -v send_alert &> /dev/null; then
                send_alert "$SEVERITY_HIGH" "missed_rotation" "$message" \
                    "{\"hours_since_last_rotation\": $hours_diff, \"threshold_hours\": $MISSED_ROTATION_THRESHOLD_HOURS}"
            fi
            return 1
        fi
    fi
    
    return 0
}

# Function to update rotation status file
update_rotation_status() {
    local status_file="$ROTATION_STATUS_FILE"
    local current_time=$(date +%s)
    local end_time=$(date +%s)
    local duration=$((end_time - ROTATION_START_TIME))
    
    mkdir -p "$(dirname "$status_file")"
    
    local status_json
    if command -v jq &> /dev/null; then
        status_json=$(jq -n \
            --argjson last_rotation_time "$current_time" \
            --argjson duration "$duration" \
            --argjson success "$ROTATION_SUCCESS" \
            --argjson files_compressed "$ROTATION_FILES_COMPRESSED" \
            --argjson files_deleted "$ROTATION_FILES_DELETED" \
            --argjson files_archived "$ROTATION_FILES_ARCHIVED" \
            --argjson space_freed "$ROTATION_SPACE_FREED" \
            --arg disk_usage_percent "$(get_disk_space_usage "$BASH_LOG_DIR")" \
            --arg available_mb "$(($(get_available_disk_space "$BASH_LOG_DIR") / 1024 / 1024))" \
            '{
                last_rotation_time: $last_rotation_time,
                duration_seconds: $duration,
                success: $success,
                files_compressed: $files_compressed,
                files_deleted: $files_deleted,
                files_archived: $files_archived,
                space_freed_bytes: $space_freed,
                disk_usage_percent: ($disk_usage_percent | tonumber),
                available_disk_space_mb: ($available_mb | tonumber),
                errors: [] | if $success == false then ["Rotation completed with errors"] else [] end
            }' 2>/dev/null)
    else
        # Fallback: simple JSON without jq
        status_json="{\"last_rotation_time\":$current_time,\"duration_seconds\":$duration,\"success\":$ROTATION_SUCCESS,\"files_compressed\":$ROTATION_FILES_COMPRESSED,\"files_deleted\":$ROTATION_FILES_DELETED,\"files_archived\":$ROTATION_FILES_ARCHIVED,\"space_freed_bytes\":$ROTATION_SPACE_FREED}"
    fi
    
    if [[ -n "$status_json" ]]; then
        echo "$status_json" > "$status_file"
        if command -v log_debug &> /dev/null; then
            log_debug "Updated rotation status file: $status_file"
        fi
    fi
}

# Function to get file age in days
get_file_age_days() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi
    
    local file_time
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        file_time=$(stat -f "%m" "$file" 2>/dev/null || echo "0")
    else
        # Linux
        file_time=$(stat -c "%Y" "$file" 2>/dev/null || echo "0")
    fi
    
    local current_time=$(date +%s)
    local age_seconds=$((current_time - file_time))
    local age_days=$((age_seconds / 86400))
    echo "$age_days"
}

# Function to compress a file
compress_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    # Skip if already compressed
    if [[ "$file" == *.gz ]] || [[ "$file" == *.bz2 ]] || [[ "$file" == *.xz ]]; then
        return 0
    fi
    
    local file_size
    if [[ "$OSTYPE" == "darwin"* ]]; then
        file_size=$(stat -f "%z" "$file" 2>/dev/null || echo "0")
    else
        file_size=$(stat -c "%s" "$file" 2>/dev/null || echo "0")
    fi
    
    if command -v log_info &> /dev/null; then
        log_info "Compressing: $(basename "$file")" "size=${file_size} bytes"
    else
        echo "Compressing: $(basename "$file")"
    fi
    
    # Try gzip first (most common), fallback to bzip2, then xz
    if command -v gzip &> /dev/null; then
        if gzip -f "$file"; then
            local compressed_file="${file}.gz"
            local compressed_size
            if [[ "$OSTYPE" == "darwin"* ]]; then
                compressed_size=$(stat -f "%z" "$compressed_file" 2>/dev/null || echo "0")
            else
                compressed_size=$(stat -c "%s" "$compressed_file" 2>/dev/null || echo "0")
            fi
            local space_saved=$((file_size - compressed_size))
            ROTATION_SPACE_FREED=$((ROTATION_SPACE_FREED + space_saved))
            ((ROTATION_FILES_COMPRESSED++))
            if command -v record_metric &> /dev/null; then
                record_metric "compression_size_saved" "$space_saved" "file=$(basename "$file")"
            fi
            return 0
        fi
    elif command -v bzip2 &> /dev/null; then
        if bzip2 -f "$file"; then
            ((ROTATION_FILES_COMPRESSED++))
            return 0
        fi
    elif command -v xz &> /dev/null; then
        if xz -f "$file"; then
            ((ROTATION_FILES_COMPRESSED++))
            return 0
        fi
    else
        if command -v log_warn &> /dev/null; then
            log_warn "No compression tool available, skipping compression"
        else
            echo "Warning: No compression tool available" >&2
        fi
        return 1
    fi
    return 1
}

# Function to archive critical logs (errors, failures)
archive_critical_log() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    # Check if log contains errors or failures
    local has_error=false
    if command -v jq &> /dev/null && [[ "$file" == *.jsonl ]]; then
        # Check for ERROR or FATAL level entries
        if jq -e 'select(.level == "ERROR" or .level == "FATAL")' "$file" &> /dev/null | head -1 | grep -q .; then
            has_error=true
        fi
    elif [[ "$file" == *.jsonl ]] || [[ "$file" == *.log ]]; then
        # Fallback: grep for error indicators
        if grep -qiE "(error|fatal|failed|failure)" "$file" 2>/dev/null; then
            has_error=true
        fi
    fi
    
    if [[ "$has_error" == "true" ]]; then
        mkdir -p "$ARCHIVE_DIR/critical"
        local archive_path="$ARCHIVE_DIR/critical/$(basename "$file")"
        
        # Compress before archiving if not already compressed
        if [[ "$file" != *.gz ]] && [[ "$file" != *.bz2 ]] && [[ "$file" != *.xz ]]; then
            compress_file "$file"
            file="${file}.gz"
            archive_path="${archive_path}.gz"
        fi
        
        if [[ -f "$file" ]]; then
            mv "$file" "$archive_path" 2>/dev/null || cp "$file" "$archive_path" && rm "$file"
            ((ROTATION_FILES_ARCHIVED++))
            if command -v log_info &> /dev/null; then
                log_info "Archived critical log: $(basename "$archive_path")"
            else
                echo "Archived critical log: $(basename "$archive_path")"
            fi
        fi
    fi
}

# Function to rotate logs by size
rotate_by_size() {
    local dir="$1"
    local max_size_mb="$2"
    local max_size_bytes=$((max_size_mb * 1024 * 1024))
    
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    
    if command -v start_span &> /dev/null; then
        start_span "rotate_by_size"
    fi
    
    if command -v log_info &> /dev/null; then
        log_info "Rotating logs by size" "dir=$dir" "max_size_mb=${max_size_mb}"
    else
        echo "Rotating logs by size in: $dir (max: ${max_size_mb}MB)"
    fi
    
    local files_rotated=0
    find "$dir" -type f \( -name "*.jsonl" -o -name "*.log" -o -name "*.json" \) ! -name "*.gz" ! -name "*.bz2" ! -name "*.xz" | while read -r file; do
        local size_bytes
        if [[ "$OSTYPE" == "darwin"* ]]; then
            size_bytes=$(stat -f "%z" "$file" 2>/dev/null || echo "0")
        else
            size_bytes=$(stat -c "%s" "$file" 2>/dev/null || echo "0")
        fi
        
        if [[ $size_bytes -gt $max_size_bytes ]]; then
            if command -v log_info &> /dev/null; then
                log_info "Rotating large file: $(basename "$file")" "size=${size_bytes} bytes"
            else
                echo "Rotating large file: $(basename "$file") (${size_bytes} bytes)"
            fi
            compress_file "$file" && ((files_rotated++))
        fi
    done
    
    if command -v record_metric &> /dev/null; then
        record_metric "rotation_files_by_size" "$files_rotated" "dir=$(basename "$dir")"
    fi
    
    if command -v end_span &> /dev/null; then
        end_span
    fi
}

# Function to apply retention policy
apply_retention() {
    local dir="$1"
    local detailed_days="$2"
    local summary_days="$3"
    local archive_days="$4"
    local compress_days="$5"
    
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    
    if command -v start_span &> /dev/null; then
        start_span "apply_retention"
    fi
    
    if command -v log_info &> /dev/null; then
        log_info "Applying retention policy" \
            "dir=$dir" \
            "detailed_days=${detailed_days}" \
            "summary_days=${summary_days}" \
            "archive_days=${archive_days}" \
            "compress_days=${compress_days}"
    else
        echo "Applying retention policy in: $dir"
        echo "  Detailed: ${detailed_days} days, Summary: ${summary_days} days, Archive: ${archive_days} days"
    fi
    
    local deleted_count=0
    local compressed_count=0
    local archived_count=0
    
    find "$dir" -type f \( -name "*.jsonl" -o -name "*.log" -o -name "*.json" -o -name "*.gz" -o -name "*.bz2" -o -name "*.xz" \) | while read -r file; do
        local age_days=$(get_file_age_days "$file")
        local basename_file=$(basename "$file")
        
        # Skip archive directory
        if [[ "$file" == *"/archive/"* ]]; then
            continue
        fi
        
        # Archive critical logs before deletion
        if [[ $age_days -ge $detailed_days ]] && [[ $age_days -lt $summary_days ]]; then
            archive_critical_log "$file"
            if [[ -f "$file" ]]; then
                archived_count=$((archived_count + 1))
            fi
        fi
        
        # Compress logs older than compress_days
        if [[ $age_days -ge $compress_days ]] && [[ "$file" != *.gz ]] && [[ "$file" != *.bz2 ]] && [[ "$file" != *.xz ]]; then
            compress_file "$file" && compressed_count=$((compressed_count + 1))
        fi
        
        # Delete logs older than summary retention (but keep archived critical logs)
        if [[ $age_days -ge $summary_days ]] && [[ "$file" != *"/archive/"* ]]; then
            # Check if this is a critical log that was archived
            local archive_path="$ARCHIVE_DIR/critical/$basename_file"
            if [[ -f "$archive_path" ]] || [[ -f "${archive_path}.gz" ]] || [[ -f "${archive_path}.bz2" ]] || [[ -f "${archive_path}.xz" ]]; then
                if command -v log_debug &> /dev/null; then
                    log_debug "Keeping archived critical log: $basename_file"
                fi
                rm -f "$file"
            elif [[ $age_days -ge $archive_days ]]; then
                # Delete even archived logs after archive retention period
                local file_size
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    file_size=$(stat -f "%z" "$file" 2>/dev/null || echo "0")
                else
                    file_size=$(stat -c "%s" "$file" 2>/dev/null || echo "0")
                fi
                ROTATION_SPACE_FREED=$((ROTATION_SPACE_FREED + file_size))
                if command -v log_info &> /dev/null; then
                    log_info "Deleting old log: $basename_file" "age_days=${age_days}" "size=${file_size} bytes"
                else
                    echo "Deleting old log: $basename_file (${age_days} days old)"
                fi
                rm -f "$file"
                deleted_count=$((deleted_count + 1))
                ((ROTATION_FILES_DELETED++))
            else
                # Move to archive if not already there
                mkdir -p "$ARCHIVE_DIR"
                mv "$file" "$ARCHIVE_DIR/" 2>/dev/null || rm -f "$file"
                deleted_count=$((deleted_count + 1))
                ((ROTATION_FILES_DELETED++))
            fi
        fi
    done
    
    # Clean up empty directories
    find "$dir" -type d -empty -delete 2>/dev/null || true
    
    if command -v record_metric &> /dev/null; then
        record_metric "retention_deleted_files" "$deleted_count" "dir=$(basename "$dir")"
        record_metric "retention_compressed_files" "$compressed_count" "dir=$(basename "$dir")"
        record_metric "retention_archived_files" "$archived_count" "dir=$(basename "$dir")"
    fi
    
    if command -v end_span &> /dev/null; then
        end_span
    fi
}

# Function to rotate bash script logs
rotate_bash_logs() {
    local exit_code=0
    if command -v start_span &> /dev/null; then
        start_span "rotate_bash_logs"
    fi
    
    if command -v log_info &> /dev/null; then
        log_info "Rotating bash script logs" "dir=$BASH_LOG_DIR"
    else
        echo "Rotating bash script logs in: $BASH_LOG_DIR"
    fi
    
    if [[ ! -d "$BASH_LOG_DIR" ]]; then
        if command -v log_warn &> /dev/null; then
            log_warn "Log directory does not exist: $BASH_LOG_DIR"
        else
            echo "Warning: Log directory does not exist: $BASH_LOG_DIR" >&2
        fi
        if command -v end_span &> /dev/null; then
            end_span
        fi
        return 0
    fi
    
    # Rotate by size first
    if ! rotate_by_size "$BASH_LOG_DIR" "$MAX_LOG_SIZE_MB"; then
        exit_code=1
    fi
    
    # Apply retention policy
    if ! apply_retention "$BASH_LOG_DIR" "$DETAILED_RETENTION_DAYS" "$SUMMARY_RETENTION_DAYS" "$ARCHIVE_RETENTION_DAYS" "$COMPRESS_AFTER_DAYS"; then
        exit_code=1
    fi
    
    if command -v log_info &> /dev/null; then
        log_info "Bash log rotation complete"
    else
        echo "Bash log rotation complete"
    fi
    
    if command -v end_span &> /dev/null; then
        end_span
    fi
    
    return $exit_code
}

# Function to get Rust log directory
get_rust_log_dir() {
    # Try to get from goose CLI if available
    if command -v goose &> /dev/null; then
        local info_output
        info_output=$(goose info 2>/dev/null || true)
        if echo "$info_output" | grep -q "Logs dir:"; then
            echo "$info_output" | grep "Logs dir:" | awk '{print $3}' | head -1
            return
        fi
    fi
    
    # Fallback to common locations
    if [[ -n "${GOOSE_PATH_ROOT:-}" ]]; then
        echo "${GOOSE_PATH_ROOT}/state/logs"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "${HOME}/Library/Application Support/goose/logs"
    else
        echo "${HOME}/.local/share/goose/logs"
    fi
}

# Function to rotate Rust logs
rotate_rust_logs() {
    local rust_log_dir
    local exit_code=0
    rust_log_dir=$(get_rust_log_dir)
    
    if command -v start_span &> /dev/null; then
        start_span "rotate_rust_logs"
    fi
    
    if command -v log_info &> /dev/null; then
        log_info "Rotating Rust logs" "dir=$rust_log_dir"
    else
        echo "Rotating Rust logs in: $rust_log_dir"
    fi
    
    if [[ ! -d "$rust_log_dir" ]]; then
        if command -v log_warn &> /dev/null; then
            log_warn "Rust log directory does not exist: $rust_log_dir"
        else
            echo "Warning: Rust log directory does not exist: $rust_log_dir" >&2
        fi
        if command -v end_span &> /dev/null; then
            end_span
        fi
        return 0
    fi
    
    # Rotate by size first
    if ! rotate_by_size "$rust_log_dir" "$MAX_LOG_SIZE_MB"; then
        exit_code=1
    fi
    
    # Apply retention policy to each component directory
    for component_dir in "$rust_log_dir"/*; do
        if [[ -d "$component_dir" ]]; then
            local component=$(basename "$component_dir")
            if command -v log_info &> /dev/null; then
                log_info "Processing component: $component"
            else
                echo "Processing component: $component"
            fi
            if ! apply_retention "$component_dir" "$DETAILED_RETENTION_DAYS" "$SUMMARY_RETENTION_DAYS" "$ARCHIVE_RETENTION_DAYS" "$COMPRESS_AFTER_DAYS"; then
                exit_code=1
            fi
        fi
    done
    
    if command -v log_info &> /dev/null; then
        log_info "Rust log rotation complete"
    else
        echo "Rust log rotation complete"
    fi
    
    if command -v end_span &> /dev/null; then
        end_span
    fi
    
    return $exit_code
}

# Main function
main() {
    local rotate_bash="${1:-true}"
    local rotate_rust="${2:-true}"
    local exit_code=0
    
    # Check for missed rotations before starting
    if ! check_missed_rotation; then
        if command -v log_warn &> /dev/null; then
            log_warn "Missed rotation detected, continuing with current rotation"
        fi
    fi
    
    # Check disk space before rotation
    local disk_space_before
    disk_space_before=$(get_disk_space_usage "$BASH_LOG_DIR")
    if command -v log_info &> /dev/null; then
        log_info "Starting log rotation and retention" \
            "disk_space_before=${disk_space_before}%" \
            "detailed_retention=${DETAILED_RETENTION_DAYS}d" \
            "summary_retention=${SUMMARY_RETENTION_DAYS}d" \
            "archive_retention=${ARCHIVE_RETENTION_DAYS}d"
    else
        echo "Starting log rotation and retention"
        echo "Configuration:"
        echo "  Detailed retention: ${DETAILED_RETENTION_DAYS} days"
        echo "  Summary retention: ${SUMMARY_RETENTION_DAYS} days"
        echo "  Archive retention: ${ARCHIVE_RETENTION_DAYS} days"
        echo "  Compress after: ${COMPRESS_AFTER_DAYS} days"
        echo "  Max log size: ${MAX_LOG_SIZE_MB}MB"
        echo "  Disk space before: ${disk_space_before}%"
        echo
    fi
    
    # Check disk space and alert if needed
    check_disk_space "$BASH_LOG_DIR" || true
    
    # Track rotation start
    if command -v start_span &> /dev/null; then
        start_span "log_rotation"
    fi
    
    # Rotate bash logs
    if [[ "$rotate_bash" != "false" ]]; then
        if ! rotate_bash_logs; then
            ROTATION_SUCCESS=false
            ROTATION_ERRORS+=("Bash log rotation failed")
            exit_code=1
        fi
    fi
    
    # Rotate Rust logs
    if [[ "$rotate_rust" != "false" ]]; then
        if ! rotate_rust_logs; then
            ROTATION_SUCCESS=false
            ROTATION_ERRORS+=("Rust log rotation failed")
            exit_code=1
        fi
    fi
    
    # Check disk space after rotation
    local disk_space_after
    disk_space_after=$(get_disk_space_usage "$BASH_LOG_DIR")
    local space_freed_mb=$((ROTATION_SPACE_FREED / 1024 / 1024))
    
    if command -v record_metric &> /dev/null; then
        record_metric "rotation_duration" "$(($(date +%s) - ROTATION_START_TIME))" "unit=seconds"
        record_metric "rotation_files_compressed" "$ROTATION_FILES_COMPRESSED" "total"
        record_metric "rotation_files_deleted" "$ROTATION_FILES_DELETED" "total"
        record_metric "rotation_files_archived" "$ROTATION_FILES_ARCHIVED" "total"
        record_metric "rotation_space_freed_mb" "$space_freed_mb" "total"
        record_metric "rotation_success" "$([ "$ROTATION_SUCCESS" = true ] && echo 1 || echo 0)" "boolean"
        record_metric "rotation_operations_completed" "$((ROTATION_FILES_COMPRESSED + ROTATION_FILES_DELETED + ROTATION_FILES_ARCHIVED))" "total"
    fi
    
    # End rotation span
    if command -v end_span &> /dev/null; then
        end_span
    fi
    
    # Update status file
    update_rotation_status
    
    # Log summary
    if command -v log_info &> /dev/null; then
        log_info "Log rotation complete" \
            "success=$ROTATION_SUCCESS" \
            "files_compressed=$ROTATION_FILES_COMPRESSED" \
            "files_deleted=$ROTATION_FILES_DELETED" \
            "files_archived=$ROTATION_FILES_ARCHIVED" \
            "space_freed_mb=$space_freed_mb" \
            "disk_space_before=${disk_space_before}%" \
            "disk_space_after=${disk_space_after}%"
    else
        echo "Log rotation complete"
        echo "  Files compressed: $ROTATION_FILES_COMPRESSED"
        echo "  Files deleted: $ROTATION_FILES_DELETED"
        echo "  Files archived: $ROTATION_FILES_ARCHIVED"
        echo "  Space freed: ${space_freed_mb}MB"
        echo "  Disk space: ${disk_space_before}% -> ${disk_space_after}%"
    fi
    
    # Alert on rotation failure
    if [[ "$ROTATION_SUCCESS" != "true" ]]; then
        local error_message="Log rotation completed with errors: ${ROTATION_ERRORS[*]}"
        if command -v log_error &> /dev/null; then
            log_error "$error_message"
        else
            echo "ERROR: $error_message" >&2
        fi
        
        if command -v send_alert &> /dev/null; then
            local errors_json
            if command -v jq &> /dev/null; then
                errors_json=$(printf '%s\n' "${ROTATION_ERRORS[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
            else
                errors_json='[]'
            fi
            send_alert "$SEVERITY_HIGH" "rotation_failure" "$error_message" \
                "{\"files_compressed\": $ROTATION_FILES_COMPRESSED, \"files_deleted\": $ROTATION_FILES_DELETED, \"errors\": $errors_json}"
        fi
    fi
    
    # Check disk space after rotation
    check_disk_space "$BASH_LOG_DIR" || true
    
    return $exit_code
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

