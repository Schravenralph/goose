#!/bin/bash

# Structured logging utilities for bash scripts
# Provides JSON logging with timestamps, trace IDs, and log levels

# Generate a unique trace ID for this script execution
TRACE_ID="${TRACE_ID:-$(uuidgen 2>/dev/null || date +%s%N | sha256sum | cut -d' ' -f1 | head -c 32)}"
export TRACE_ID

# Get script name
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-$0}")}"

# Log directory
LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
mkdir -p "$LOG_DIR"

# Log file with timestamp
LOG_FILE="${LOG_FILE:-$LOG_DIR/${SCRIPT_NAME}-$(date +%Y%m%d_%H%M%S).jsonl}"

# Metrics file
METRICS_FILE="${METRICS_FILE:-$LOG_DIR/${SCRIPT_NAME}-metrics-$(date +%Y%m%d_%H%M%S).json}"

# Initialize metrics
declare -A METRICS
METRICS[start_time]=$(date +%s.%N)
METRICS[script_name]="$SCRIPT_NAME"
METRICS[trace_id]="$TRACE_ID"
METRICS[hostname]="$(hostname)"
METRICS[user]="$(whoami)"

# Get git context if available
if command -v git &> /dev/null && git rev-parse --git-dir &> /dev/null; then
    METRICS[git_branch]="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
    METRICS[git_commit]="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
    METRICS[git_remote]="$(git config --get remote.origin.url 2>/dev/null || echo 'unknown')"
else
    METRICS[git_branch]="unknown"
    METRICS[git_commit]="unknown"
    METRICS[git_remote]="unknown"
fi

# Get project version if Cargo.toml exists
if [[ -f "Cargo.toml" ]]; then
    METRICS[project_version]="$(grep -m1 '^version' Cargo.toml | sed 's/.*= *"\(.*\)".*/\1/' || echo 'unknown')"
    METRICS[project_name]="$(grep -m1 '^name' Cargo.toml | sed 's/.*= *"\(.*\)".*/\1/' || echo 'unknown')"
else
    METRICS[project_version]="unknown"
    METRICS[project_name]="unknown"
fi

# Function to log a message with structured JSON format
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    local span_id="${SPAN_ID:-}"
    
    # Create JSON log entry
    local log_entry=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg level "$level" \
        --arg trace_id "$TRACE_ID" \
        --arg span_id "$span_id" \
        --arg script "$SCRIPT_NAME" \
        --arg message "$message" \
        --arg hostname "$(hostname)" \
        --arg user "$(whoami)" \
        --arg pid "$$" \
        '{
            timestamp: $timestamp,
            level: $level,
            trace_id: $trace_id,
            span_id: $span_id,
            script: $script,
            message: $message,
            hostname: $hostname,
            user: $user,
            pid: ($pid | tonumber)
        }' 2>/dev/null)
    
    # If jq is not available, create simple JSON
    if [[ -z "$log_entry" ]]; then
        log_entry="{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"trace_id\":\"$TRACE_ID\",\"span_id\":\"$span_id\",\"script\":\"$SCRIPT_NAME\",\"message\":\"$message\",\"hostname\":\"$(hostname)\",\"user\":\"$(whoami)\",\"pid\":$$}"
    fi
    
    # Write to log file
    echo "$log_entry" >> "$LOG_FILE"
    
    # Also output to console with appropriate formatting
    case "$level" in
        DEBUG)
            echo "🔍 [DEBUG] $message" >&2
            ;;
        INFO)
            echo "ℹ️  [INFO] $message"
            ;;
        WARN)
            echo "⚠️  [WARN] $message" >&2
            ;;
        ERROR)
            echo "❌ [ERROR] $message" >&2
            ;;
        FATAL)
            echo "💥 [FATAL] $message" >&2
            ;;
        *)
            echo "[$level] $message"
            ;;
    esac
}

# Convenience functions for different log levels
log_debug() { log "DEBUG" "$@"; }
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_fatal() { log "FATAL" "$@"; exit 1; }

# Start a span (operation tracking)
start_span() {
    local span_name="$1"
    local span_id=$(uuidgen 2>/dev/null || date +%s%N | sha256sum | cut -d' ' -f1 | head -c 16)
    # Store parent span ID before setting new one
    local parent_span_id="${SPAN_ID:-}"
    export PARENT_SPAN_ID="$parent_span_id"
    export SPAN_ID="$span_id"
    export SPAN_NAME="$span_name"
    export SPAN_START_TIME=$(date +%s.%N)
    log_info "Starting span: $span_name" "span_id=$span_id"
    
    # Track span for OTLP export if OTLP is enabled
    if [[ -n "$(type -t otlp_start_span)" ]] && [[ "$(type -t otlp_start_span)" == "function" ]] && [[ "${OTLP_ENABLED:-}" == "true" ]]; then
        otlp_start_span "$span_id" "$span_name" "$TRACE_ID" "$parent_span_id"
    fi
}

# End a span
end_span() {
    if [[ -n "${SPAN_START_TIME:-}" ]]; then
        local end_time=$(date +%s.%N)
        local current_span_id="${SPAN_ID:-}"
        # Calculate duration - use awk if bc is not available
        local duration
        if command -v bc &> /dev/null; then
            duration=$(echo "$end_time - $SPAN_START_TIME" | bc -l 2>/dev/null || echo "0")
        else
            # Fallback to awk for duration calculation
            duration=$(awk "BEGIN {printf \"%.3f\", $end_time - $SPAN_START_TIME}" 2>/dev/null || echo "0")
        fi
        log_info "Ending span: ${SPAN_NAME:-unknown}" "duration=${duration}s" "span_id=${SPAN_ID:-}"
        record_metric "span_duration" "$duration" "span_name=${SPAN_NAME:-unknown}"
        
        # Export span to OTLP if enabled
        if [[ -n "$current_span_id" ]] && [[ -n "$(type -t otlp_end_span)" ]] && [[ "$(type -t otlp_end_span)" == "function" ]] && [[ "${OTLP_ENABLED:-}" == "true" ]]; then
            local status="OK"
            if [[ "${EXIT_CODE:-0}" != "0" ]] && [[ -n "${SPAN_NAME:-}" ]]; then
                status="ERROR"
            fi
            otlp_end_span "$current_span_id" "$status" || true
        fi
        
        unset SPAN_ID SPAN_NAME SPAN_START_TIME
    fi
}

# Record a metric
record_metric() {
    local metric_name="$1"
    local metric_value="$2"
    shift 2
    local labels="$*"
    
    # Store in metrics array
    local key="${metric_name}_${labels}"
    METRICS["$key"]="$metric_value"
    
    log_debug "Metric recorded: $metric_name=$metric_value $labels"
}

# Increment a counter
increment_counter() {
    local counter_name="$1"
    local current_value="${METRICS[$counter_name]:-0}"
    METRICS["$counter_name"]=$((current_value + 1))
    log_debug "Counter incremented: $counter_name=${METRICS[$counter_name]}"
}

# Write metrics to file
write_metrics() {
    local end_time=$(date +%s.%N)
    # Calculate duration - use awk if bc is not available
    local duration
    if command -v bc &> /dev/null; then
        duration=$(echo "$end_time - ${METRICS[start_time]}" | bc -l 2>/dev/null || echo "0")
    else
        # Fallback to awk for duration calculation
        duration=$(awk "BEGIN {printf \"%.3f\", $end_time - ${METRICS[start_time]}}" 2>/dev/null || echo "0")
    fi
    METRICS[end_time]="$end_time"
    METRICS[duration]="$duration"
    METRICS[exit_code]="${EXIT_CODE:-0}"
    
    # Convert metrics array to JSON
    local metrics_json="{"
    local first=true
    for key in "${!METRICS[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            metrics_json+=","
        fi
        # Escape quotes in values
        local value="${METRICS[$key]}"
        value="${value//\"/\\\"}"
        metrics_json+="\"$key\":\"$value\""
    done
    metrics_json+="}"
    
    # Use jq if available for pretty formatting
    if command -v jq &> /dev/null; then
        echo "$metrics_json" | jq '.' > "$METRICS_FILE" 2>/dev/null || echo "$metrics_json" > "$METRICS_FILE"
    else
        echo "$metrics_json" > "$METRICS_FILE"
    fi
    
    if command -v log_info &> /dev/null; then
        log_info "Metrics written to: $METRICS_FILE"
    fi
}

# Load alerting utilities if available
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ -f "$SCRIPT_DIR/alerting-utils.sh" ]]; then
    source "$SCRIPT_DIR/alerting-utils.sh"
fi

# Load OTLP utilities if available
if [[ -f "$SCRIPT_DIR/otlp-utils.sh" ]]; then
    source "$SCRIPT_DIR/otlp-utils.sh"
fi

# Script-triggered log rotation configuration
# These can be overridden via environment variables
GOOSE_LOG_ROTATION_ENABLED="${GOOSE_LOG_ROTATION_ENABLED:-true}"
GOOSE_LOG_ROTATION_SIZE_THRESHOLD_MB="${GOOSE_LOG_ROTATION_SIZE_THRESHOLD_MB:-50}"
GOOSE_LOG_ROTATION_COUNT_THRESHOLD="${GOOSE_LOG_ROTATION_COUNT_THRESHOLD:-100}"
GOOSE_LOG_ROTATION_DEFERRED="${GOOSE_LOG_ROTATION_DEFERRED:-true}"

# Lock file for rotation (prevents concurrent rotations)
ROTATION_LOCK_FILE="${LOG_DIR}/.rotation.lock"

# Function to get total size of log files in directory (in bytes)
get_log_dir_size() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "0"
        return
    fi
    
    local total_size=0
    # Count only uncompressed log files
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local size
            if [[ "$OSTYPE" == "darwin"* ]]; then
                size=$(stat -f "%z" "$file" 2>/dev/null || echo "0")
            else
                size=$(stat -c "%s" "$file" 2>/dev/null || echo "0")
            fi
            total_size=$((total_size + size))
        fi
    done < <(find "$dir" -type f \( -name "*.jsonl" -o -name "*.log" -o -name "*.json" \) ! -name "*.gz" ! -name "*.bz2" ! -name "*.xz" 2>/dev/null)
    
    echo "$total_size"
}

# Function to count log files in directory
get_log_file_count() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "0"
        return
    fi
    
    # Count only uncompressed log files
    find "$dir" -type f \( -name "*.jsonl" -o -name "*.log" -o -name "*.json" \) ! -name "*.gz" ! -name "*.bz2" ! -name "*.xz" 2>/dev/null | wc -l | tr -d ' '
}

# Function to check if rotation is needed
check_rotation_needed() {
    if [[ "${GOOSE_LOG_ROTATION_ENABLED}" != "true" ]]; then
        return 1
    fi
    
    if [[ ! -d "$LOG_DIR" ]]; then
        return 1
    fi
    
    # Check size threshold
    local total_size_bytes=$(get_log_dir_size "$LOG_DIR")
    local size_threshold_bytes=$((GOOSE_LOG_ROTATION_SIZE_THRESHOLD_MB * 1024 * 1024))
    
    if [[ $total_size_bytes -gt $size_threshold_bytes ]]; then
        log_debug "Rotation needed: size threshold exceeded (${total_size_bytes} bytes > ${size_threshold_bytes} bytes)"
        return 0
    fi
    
    # Check count threshold
    local file_count=$(get_log_file_count "$LOG_DIR")
    
    if [[ $file_count -gt $GOOSE_LOG_ROTATION_COUNT_THRESHOLD ]]; then
        log_debug "Rotation needed: count threshold exceeded (${file_count} files > ${GOOSE_LOG_ROTATION_COUNT_THRESHOLD} files)"
        return 0
    fi
    
    return 1
}

# Function to trigger log rotation asynchronously with file locking
trigger_log_rotation() {
    if ! check_rotation_needed; then
        return 0
    fi
    
    # Check if rotation script exists
    local rotation_script="${SCRIPT_DIR}/rotate-logs.sh"
    if [[ ! -f "$rotation_script" ]]; then
        log_warn "Rotation script not found: $rotation_script"
        return 1
    fi
    
    # Create lock file directory if needed
    mkdir -p "$(dirname "$ROTATION_LOCK_FILE")"
    
    # Try to acquire lock using flock (non-blocking)
    if command -v flock &> /dev/null; then
        # Use flock for file locking (preferred method)
        (
            exec 200>"$ROTATION_LOCK_FILE"
            if flock -n 200; then
                log_info "Triggering log rotation (size or count threshold exceeded)"
                record_metric "rotation_triggered" "1" "trigger=script" "threshold=size_or_count"
                increment_counter "rotation_trigger_count"
                
                # Run rotation in background to avoid blocking
                if [[ "${GOOSE_LOG_ROTATION_DEFERRED}" == "true" ]]; then
                    # Deferred: run in background, detached from current process
                    nohup bash "$rotation_script" true false >/dev/null 2>&1 &
                else
                    # Immediate: run in background but wait briefly
                    bash "$rotation_script" true false >/dev/null 2>&1 &
                fi
            else
                log_debug "Rotation already in progress (lock held), skipping"
                record_metric "rotation_skipped" "1" "reason=lock_held"
            fi
        )
    else
        # Fallback: use simple file-based locking
        if [[ -f "$ROTATION_LOCK_FILE" ]]; then
            # Check if lock is stale (older than 5 minutes)
            local lock_age
            if [[ "$OSTYPE" == "darwin"* ]]; then
                lock_age=$(($(date +%s) - $(stat -f "%m" "$ROTATION_LOCK_FILE" 2>/dev/null || echo "0")))
            else
                lock_age=$(($(date +%s) - $(stat -c "%Y" "$ROTATION_LOCK_FILE" 2>/dev/null || echo "0")))
            fi
            
            if [[ $lock_age -lt 300 ]]; then
                log_debug "Rotation already in progress (lock file exists), skipping"
                record_metric "rotation_skipped" "1" "reason=lock_file_exists"
                return 0
            else
                log_warn "Removing stale rotation lock file (age: ${lock_age}s)"
                rm -f "$ROTATION_LOCK_FILE"
            fi
        fi
        
        # Create lock file
        echo "$$" > "$ROTATION_LOCK_FILE"
        
        log_info "Triggering log rotation (size or count threshold exceeded)"
        record_metric "rotation_triggered" "1" "trigger=script" "threshold=size_or_count"
        increment_counter "rotation_trigger_count"
        
        # Run rotation in background
        if [[ "${GOOSE_LOG_ROTATION_DEFERRED}" == "true" ]]; then
            nohup bash "$rotation_script" true false >/dev/null 2>&1 &
        else
            bash "$rotation_script" true false >/dev/null 2>&1 &
        fi
        
        # Remove lock file after a delay (allowing rotation to start)
        (sleep 2 && rm -f "$ROTATION_LOCK_FILE") &
    fi
}

# Trap to ensure metrics are written on exit, rotation is triggered if needed, and alerts are sent if needed
trap 'EXIT_CODE=$?; write_metrics; trigger_log_rotation; end_span; if command -v check_script_failure &> /dev/null; then check_script_failure "$EXIT_CODE"; fi; if command -v analyze_metrics_and_alert &> /dev/null && [[ -n "${METRICS_FILE:-}" ]] && [[ -f "$METRICS_FILE" ]]; then analyze_metrics_and_alert "$METRICS_FILE"; fi' EXIT

# Export trace context for propagation (if OTLP utils loaded)
if [[ -n "$(type -t export_trace_context_env)" ]] && [[ "$(type -t export_trace_context_env)" == "function" ]]; then
    export_trace_context_env || true
fi

# Initialize logging
log_info "Script started" "trace_id=$TRACE_ID" "log_file=$LOG_FILE"
log_info "Context" \
    "git_branch=${METRICS[git_branch]}" \
    "git_commit=${METRICS[git_commit]}" \
    "project_name=${METRICS[project_name]}" \
    "project_version=${METRICS[project_version]}"

