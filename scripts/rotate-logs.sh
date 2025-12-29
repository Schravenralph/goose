#!/bin/bash

# Log rotation and retention script for Goose logs
# Handles both bash script logs (/tmp/goose-logs/) and Rust logs (state_dir/logs/)

set -euo pipefail

# Source logging utilities if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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
    
    print_info "Compressing: $(basename "$file")"
    
    # Try gzip first (most common), fallback to bzip2, then xz
    if command -v gzip &> /dev/null; then
        gzip -f "$file" && return 0
    elif command -v bzip2 &> /dev/null; then
        bzip2 -f "$file" && return 0
    elif command -v xz &> /dev/null; then
        xz -f "$file" && return 0
    else
        print_warning "No compression tool available, skipping compression"
        return 1
    fi
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
            print_info "Archived critical log: $(basename "$archive_path")"
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
    
    print_info "Rotating logs by size in: $dir (max: ${max_size_mb}MB)"
    
    find "$dir" -type f \( -name "*.jsonl" -o -name "*.log" -o -name "*.json" \) ! -name "*.gz" ! -name "*.bz2" ! -name "*.xz" | while read -r file; do
        local size_bytes
        if [[ "$OSTYPE" == "darwin"* ]]; then
            size_bytes=$(stat -f "%z" "$file" 2>/dev/null || echo "0")
        else
            size_bytes=$(stat -c "%s" "$file" 2>/dev/null || echo "0")
        fi
        
        if [[ $size_bytes -gt $max_size_bytes ]]; then
            print_info "Rotating large file: $(basename "$file") (${size_bytes} bytes)"
            compress_file "$file"
        fi
    done
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
    
    print_info "Applying retention policy in: $dir"
    print_info "  Detailed: ${detailed_days} days, Summary: ${summary_days} days, Archive: ${archive_days} days"
    
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
                print_info "Keeping archived critical log: $basename_file"
                rm -f "$file"
            elif [[ $age_days -ge $archive_days ]]; then
                # Delete even archived logs after archive retention period
                print_info "Deleting old log: $basename_file (${age_days} days old)"
                rm -f "$file"
                deleted_count=$((deleted_count + 1))
            else
                # Move to archive if not already there
                mkdir -p "$ARCHIVE_DIR"
                mv "$file" "$ARCHIVE_DIR/" 2>/dev/null || rm -f "$file"
                deleted_count=$((deleted_count + 1))
            fi
        fi
    done
    
    # Clean up empty directories
    find "$dir" -type d -empty -delete 2>/dev/null || true
}

# Function to rotate bash script logs
rotate_bash_logs() {
    print_info "Rotating bash script logs in: $BASH_LOG_DIR"
    
    if [[ ! -d "$BASH_LOG_DIR" ]]; then
        print_warning "Log directory does not exist: $BASH_LOG_DIR"
        return 0
    fi
    
    # Rotate by size first
    rotate_by_size "$BASH_LOG_DIR" "$MAX_LOG_SIZE_MB"
    
    # Apply retention policy
    apply_retention "$BASH_LOG_DIR" "$DETAILED_RETENTION_DAYS" "$SUMMARY_RETENTION_DAYS" "$ARCHIVE_RETENTION_DAYS" "$COMPRESS_AFTER_DAYS"
    
    print_success "Bash log rotation complete"
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
    rust_log_dir=$(get_rust_log_dir)
    
    print_info "Rotating Rust logs in: $rust_log_dir"
    
    if [[ ! -d "$rust_log_dir" ]]; then
        print_warning "Rust log directory does not exist: $rust_log_dir"
        return 0
    fi
    
    # Rotate by size first
    rotate_by_size "$rust_log_dir" "$MAX_LOG_SIZE_MB"
    
    # Apply retention policy to each component directory
    for component_dir in "$rust_log_dir"/*; do
        if [[ -d "$component_dir" ]]; then
            local component=$(basename "$component_dir")
            print_info "Processing component: $component"
            apply_retention "$component_dir" "$DETAILED_RETENTION_DAYS" "$SUMMARY_RETENTION_DAYS" "$ARCHIVE_RETENTION_DAYS" "$COMPRESS_AFTER_DAYS"
        fi
    done
    
    print_success "Rust log rotation complete"
}

# Main function
main() {
    local rotate_bash="${1:-true}"
    local rotate_rust="${2:-true}"
    
    print_info "Starting log rotation and retention"
    print_info "Configuration:"
    print_info "  Detailed retention: ${DETAILED_RETENTION_DAYS} days"
    print_info "  Summary retention: ${SUMMARY_RETENTION_DAYS} days"
    print_info "  Archive retention: ${ARCHIVE_RETENTION_DAYS} days"
    print_info "  Compress after: ${COMPRESS_AFTER_DAYS} days"
    print_info "  Max log size: ${MAX_LOG_SIZE_MB}MB"
    echo
    
    if [[ "$rotate_bash" != "false" ]]; then
        rotate_bash_logs
        echo
    fi
    
    if [[ "$rotate_rust" != "false" ]]; then
        rotate_rust_logs
        echo
    fi
    
    print_success "Log rotation complete"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

