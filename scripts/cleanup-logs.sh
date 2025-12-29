#!/usr/bin/env bash
# cleanup-logs.sh - Cleanup and archive old log files based on retention policies

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="cleanup-logs"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

# Default configuration
LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$LOG_DIR/archive}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-365}"
METRICS_RETENTION_DAYS="${METRICS_RETENTION_DAYS:-90}"
MAX_LOG_SIZE_MB="${MAX_LOG_SIZE_MB:-100}"
COMPRESS_ARCHIVES="${COMPRESS_ARCHIVES:-true}"

# Display usage information
function show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --log-dir DIR              Log directory (default: /tmp/goose-logs)"
    echo "  --archive-dir DIR          Archive directory (default: LOG_DIR/archive)"
    echo "  --retention-days DAYS      Days to keep regular logs (default: 30)"
    echo "  --archive-retention-days DAYS  Days to keep archived logs (default: 365)"
    echo "  --metrics-retention-days DAYS  Days to keep metrics files (default: 90)"
    echo "  --max-log-size-mb MB       Maximum log file size in MB before rotation (default: 100)"
    echo "  --compress                 Compress archived logs (default: true)"
    echo "  --no-compress              Do not compress archived logs"
    echo "  --dry-run                  Show what would be done without making changes"
    echo "  -h, --help                 Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  LOG_DIR                    Log directory"
    echo "  ARCHIVE_DIR                Archive directory"
    echo "  RETENTION_DAYS             Retention period for regular logs (days)"
    echo "  ARCHIVE_RETENTION_DAYS     Retention period for archived logs (days)"
    echo "  METRICS_RETENTION_DAYS     Retention period for metrics files (days)"
    echo "  MAX_LOG_SIZE_MB            Maximum log file size before rotation (MB)"
    echo "  COMPRESS_ARCHIVES          Compress archives (true/false)"
}

# Parse command line arguments
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --archive-dir)
            ARCHIVE_DIR="$2"
            shift 2
            ;;
        --retention-days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --archive-retention-days)
            ARCHIVE_RETENTION_DAYS="$2"
            shift 2
            ;;
        --metrics-retention-days)
            METRICS_RETENTION_DAYS="$2"
            shift 2
            ;;
        --max-log-size-mb)
            MAX_LOG_SIZE_MB="$2"
            shift 2
            ;;
        --compress)
            COMPRESS_ARCHIVES="true"
            shift
            ;;
        --no-compress)
            COMPRESS_ARCHIVES="false"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

# Validate directories
if [[ ! -d "$LOG_DIR" ]]; then
    if command -v log_error &> /dev/null; then
        log_error "Log directory does not exist: $LOG_DIR"
    else
        echo "Error: Log directory does not exist: $LOG_DIR" >&2
    fi
    exit 1
fi

# Create archive directory if it doesn't exist
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$ARCHIVE_DIR"
fi

# Calculate cutoff timestamps (seconds since epoch)
CUTOFF_TIME=$(date -d "$RETENTION_DAYS days ago" +%s 2>/dev/null || date -v-${RETENTION_DAYS}d +%s 2>/dev/null || echo "0")
ARCHIVE_CUTOFF_TIME=$(date -d "$ARCHIVE_RETENTION_DAYS days ago" +%s 2>/dev/null || date -v-${ARCHIVE_RETENTION_DAYS}d +%s 2>/dev/null || echo "0")
METRICS_CUTOFF_TIME=$(date -d "$METRICS_RETENTION_DAYS days ago" +%s 2>/dev/null || date -v-${METRICS_RETENTION_DAYS}d +%s 2>/dev/null || echo "0")

# Convert MB to bytes
MAX_LOG_SIZE_BYTES=$((MAX_LOG_SIZE_MB * 1024 * 1024))

# Statistics
STATS_DELETED_LOGS=0
STATS_DELETED_METRICS=0
STATS_ARCHIVED_LOGS=0
STATS_COMPRESSED=0
STATS_DELETED_ARCHIVES=0
STATS_ROTATED=0

if command -v log_info &> /dev/null; then
    start_span "log_cleanup"
    log_info "Starting log cleanup" \
        "log_dir=$LOG_DIR" \
        "retention_days=$RETENTION_DAYS" \
        "archive_retention_days=$ARCHIVE_RETENTION_DAYS" \
        "metrics_retention_days=$METRICS_RETENTION_DAYS" \
        "dry_run=$DRY_RUN"
fi

# Function to check if log file contains errors or failures
contains_errors_or_failures() {
    local file="$1"
    
    # Check if it's a JSONL file
    if [[ "$file" == *.jsonl ]]; then
        # Look for ERROR or FATAL level entries
        if command -v jq &> /dev/null; then
            if jq -e 'select(.level == "ERROR" or .level == "FATAL")' "$file" 2>/dev/null | head -1 | grep -q .; then
                return 0
            fi
        else
            # Fallback: grep for ERROR or FATAL in JSON
            if grep -q '"level":"ERROR"' "$file" 2>/dev/null || grep -q '"level":"FATAL"' "$file" 2>/dev/null; then
                return 0
            fi
        fi
    fi
    
    # Check metrics files for failure indicators
    if [[ "$file" == *-metrics-*.json ]]; then
        if command -v jq &> /dev/null; then
            # Check for exit_code != 0 or failure indicators
            local exit_code=$(jq -r '.exit_code // 0' "$file" 2>/dev/null || echo "0")
            if [[ "$exit_code" != "0" ]]; then
                return 0
            fi
        else
            # Fallback: grep for failure patterns
            if grep -q '"exit_code":"[^0]' "$file" 2>/dev/null; then
                return 0
            fi
        fi
    fi
    
    return 1
}

# Function to get file modification time (seconds since epoch)
get_file_mtime() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f %m "$file" 2>/dev/null || echo "0"
    else
        stat -c %Y "$file" 2>/dev/null || echo "0"
    fi
}

# Function to get file size in bytes
get_file_size() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f %z "$file" 2>/dev/null || echo "0"
    else
        stat -c %s "$file" 2>/dev/null || echo "0"
    fi
}

# Process log files
if command -v log_info &> /dev/null; then
    log_info "Processing log files in $LOG_DIR"
fi

while IFS= read -r -d '' file; do
    # Skip archive directory
    [[ "$file" == "$ARCHIVE_DIR"* ]] && continue
    
    file_mtime=$(get_file_mtime "$file")
    file_size=$(get_file_size "$file")
    file_basename=$(basename "$file")
    
    # Check if file is old enough for cleanup
    if [[ $file_mtime -lt $CUTOFF_TIME ]]; then
        # Check if it contains errors/failures - archive it
        if contains_errors_or_failures "$file"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                if command -v log_info &> /dev/null; then
                    log_info "Would archive (contains errors): $file_basename"
                else
                    echo "Would archive (contains errors): $file_basename"
                fi
            else
                archive_file="$ARCHIVE_DIR/$file_basename"
                cp "$file" "$archive_file"
                
                # Compress if enabled
                if [[ "$COMPRESS_ARCHIVES" == "true" ]] && command -v gzip &> /dev/null; then
                    gzip "$archive_file"
                    archive_file="${archive_file}.gz"
                    ((STATS_COMPRESSED++))
                fi
                
                rm "$file"
                
                if command -v log_info &> /dev/null; then
                    log_debug "Archived: $file_basename -> $(basename "$archive_file")"
                fi
                ((STATS_ARCHIVED_LOGS++))
            fi
        else
            # Regular log file without errors - delete it
            if [[ "$DRY_RUN" == "true" ]]; then
                if command -v log_info &> /dev/null; then
                    log_info "Would delete: $file_basename"
                else
                    echo "Would delete: $file_basename"
                fi
            else
                rm "$file"
                if command -v log_debug &> /dev/null; then
                    log_debug "Deleted: $file_basename"
                fi
                ((STATS_DELETED_LOGS++))
            fi
        fi
    fi
done < <(find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.jsonl" -o -name "*.json" \) -print0 2>/dev/null || true)

# Process metrics files separately
if command -v log_info &> /dev/null; then
    log_info "Processing metrics files"
fi

while IFS= read -r -d '' file; do
    [[ "$file" == "$ARCHIVE_DIR"* ]] && continue
    
    # Only process metrics files (not regular logs)
    [[ "$file" != *-metrics-*.json ]] && continue
    
    file_mtime=$(get_file_mtime "$file")
    file_basename=$(basename "$file")
    
    # Check if metrics file is old enough for cleanup
    if [[ $file_mtime -lt $METRICS_CUTOFF_TIME ]]; then
        # Check if it indicates failure - archive it
        if contains_errors_or_failures "$file"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                if command -v log_info &> /dev/null; then
                    log_info "Would archive metrics (contains failures): $file_basename"
                else
                    echo "Would archive metrics (contains failures): $file_basename"
                fi
            else
                archive_file="$ARCHIVE_DIR/$file_basename"
                cp "$file" "$archive_file"
                
                if [[ "$COMPRESS_ARCHIVES" == "true" ]] && command -v gzip &> /dev/null; then
                    gzip "$archive_file"
                    archive_file="${archive_file}.gz"
                    ((STATS_COMPRESSED++))
                fi
                
                rm "$file"
                ((STATS_ARCHIVED_LOGS++))
            fi
        else
            # Delete old metrics file
            if [[ "$DRY_RUN" == "true" ]]; then
                if command -v log_info &> /dev/null; then
                    log_info "Would delete metrics: $file_basename"
                else
                    echo "Would delete metrics: $file_basename"
                fi
            else
                rm "$file"
                ((STATS_DELETED_METRICS++))
            fi
        fi
    fi
done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*-metrics-*.json" -print0 2>/dev/null || true)

# Clean up old archives
if [[ -d "$ARCHIVE_DIR" ]]; then
    if command -v log_info &> /dev/null; then
        log_info "Cleaning up old archives"
    fi
    
    while IFS= read -r -d '' file; do
        file_mtime=$(get_file_mtime "$file")
        file_basename=$(basename "$file")
        
        if [[ $file_mtime -lt $ARCHIVE_CUTOFF_TIME ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                if command -v log_info &> /dev/null; then
                    log_info "Would delete old archive: $file_basename"
                else
                    echo "Would delete old archive: $file_basename"
                fi
            else
                rm "$file"
                if command -v log_debug &> /dev/null; then
                    log_debug "Deleted old archive: $file_basename"
                fi
                ((STATS_DELETED_ARCHIVES++))
            fi
        fi
    done < <(find "$ARCHIVE_DIR" -type f -print0 2>/dev/null || true)
fi

# Log rotation based on size (optional - log files already have timestamps, so this is less critical)
# But we can still check and warn about large files
if command -v log_info &> /dev/null; then
    log_info "Checking for large log files"
fi

while IFS= read -r -d '' file; do
    [[ "$file" == "$ARCHIVE_DIR"* ]] && continue
    
    file_size=$(get_file_size "$file")
    file_basename=$(basename "$file")
    
    if [[ $file_size -gt $MAX_LOG_SIZE_BYTES ]]; then
        if command -v log_warn &> /dev/null; then
            log_warn "Large log file detected: $file_basename ($(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "${file_size} bytes"))"
        else
            echo "Warning: Large log file detected: $file_basename" >&2
        fi
    fi
done < <(find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.jsonl" -o -name "*.json" \) -print0 2>/dev/null || true)

# Summary
if command -v log_info &> /dev/null; then
    log_info "Cleanup summary" \
        "deleted_logs=$STATS_DELETED_LOGS" \
        "deleted_metrics=$STATS_DELETED_METRICS" \
        "archived_logs=$STATS_ARCHIVED_LOGS" \
        "compressed=$STATS_COMPRESSED" \
        "deleted_archives=$STATS_DELETED_ARCHIVES" \
        "rotated=$STATS_ROTATED"
    
    if command -v record_metric &> /dev/null; then
        record_metric "cleanup_deleted_logs" "$STATS_DELETED_LOGS"
        record_metric "cleanup_deleted_metrics" "$STATS_DELETED_METRICS"
        record_metric "cleanup_archived_logs" "$STATS_ARCHIVED_LOGS"
        record_metric "cleanup_compressed" "$STATS_COMPRESSED"
        record_metric "cleanup_deleted_archives" "$STATS_DELETED_ARCHIVES"
    fi
    
    end_span
else
    echo ""
    echo "Cleanup summary:"
    echo "  Deleted logs: $STATS_DELETED_LOGS"
    echo "  Deleted metrics: $STATS_DELETED_METRICS"
    echo "  Archived logs: $STATS_ARCHIVED_LOGS"
    echo "  Compressed: $STATS_COMPRESSED"
    echo "  Deleted old archives: $STATS_DELETED_ARCHIVES"
fi

