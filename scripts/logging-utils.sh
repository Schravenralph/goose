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
    export SPAN_ID="$span_id"
    export SPAN_NAME="$span_name"
    export SPAN_START_TIME=$(date +%s.%N)
    log_info "Starting span: $span_name" "span_id=$span_id"
}

# End a span
end_span() {
    if [[ -n "${SPAN_START_TIME:-}" ]]; then
        local end_time=$(date +%s.%N)
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

# Trap to ensure metrics are written on exit and alerts are sent if needed
trap 'EXIT_CODE=$?; write_metrics; end_span; if command -v check_script_failure &> /dev/null; then check_script_failure "$EXIT_CODE"; fi; if command -v analyze_metrics_and_alert &> /dev/null && [[ -n "${METRICS_FILE:-}" ]] && [[ -f "$METRICS_FILE" ]]; then analyze_metrics_and_alert "$METRICS_FILE"; fi' EXIT

# Initialize logging
log_info "Script started" "trace_id=$TRACE_ID" "log_file=$LOG_FILE"
log_info "Context" \
    "git_branch=${METRICS[git_branch]}" \
    "git_commit=${METRICS[git_commit]}" \
    "project_name=${METRICS[project_name]}" \
    "project_version=${METRICS[project_version]}"

