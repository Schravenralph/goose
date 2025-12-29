#!/bin/bash

# Datadog log and metrics forwarder for Goose
# Forwards JSON logs and metrics to Datadog API
# Usage: ./datadog-forwarder.sh [--logs] [--metrics] [--api-key KEY] [--site SITE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="datadog-forwarder"

# Source logging utilities
source "$SCRIPT_DIR/logging-utils.sh"

# Default configuration
FORWARD_LOGS=true
FORWARD_METRICS=true
DD_API_KEY="${DD_API_KEY:-}"
DD_SITE="${DD_SITE:-datadoghq.com}"
LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
METRICS_DIR="${METRICS_DIR:-/tmp/goose-logs}"
BATCH_SIZE=100
INTERVAL=60

# Datadog API endpoints
DD_LOGS_ENDPOINT="https://http-intake.logs.${DD_SITE}/v1/input"
DD_METRICS_ENDPOINT="https://api.${DD_SITE}/api/v1/series"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --logs-only)
            FORWARD_LOGS=true
            FORWARD_METRICS=false
            shift
            ;;
        --metrics-only)
            FORWARD_LOGS=false
            FORWARD_METRICS=true
            shift
            ;;
        --api-key)
            DD_API_KEY="$2"
            shift 2
            ;;
        --site)
            DD_SITE="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --metrics-dir)
            METRICS_DIR="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --logs-only          Forward only logs"
            echo "  --metrics-only       Forward only metrics"
            echo "  --api-key KEY        Datadog API key (or set DD_API_KEY)"
            echo "  --site SITE          Datadog site (default: datadoghq.com)"
            echo "  --log-dir DIR        Directory containing log files (default: /tmp/goose-logs)"
            echo "  --metrics-dir DIR    Directory containing metrics files (default: /tmp/goose-logs)"
            echo "  --interval SECONDS    Forwarding interval in seconds (default: 60)"
            echo ""
            echo "Environment variables:"
            echo "  DD_API_KEY           Datadog API key (required)"
            echo "  DD_SITE              Datadog site (default: datadoghq.com)"
            echo "  LOG_DIR              Directory containing log files"
            echo "  METRICS_DIR          Directory containing metrics files"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check for API key
if [[ -z "$DD_API_KEY" ]]; then
    log_error "DD_API_KEY is required. Set it via --api-key or DD_API_KEY environment variable."
    exit 1
fi

# Check dependencies
if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed. Please install jq first."
    exit 1
fi

if ! command -v curl &> /dev/null; then
    log_error "curl is required but not installed. Please install curl first."
    exit 1
fi

# Ensure directories exist
mkdir -p "$LOG_DIR"
mkdir -p "$METRICS_DIR"

# Track processed files to avoid duplicates
PROCESSED_LOGS_FILE="/tmp/goose-datadog-processed-logs.txt"
PROCESSED_METRICS_FILE="/tmp/goose-datadog-processed-metrics.txt"

touch "$PROCESSED_LOGS_FILE"
touch "$PROCESSED_METRICS_FILE"

# Function to forward logs to Datadog
forward_logs() {
    start_span "forward_logs"
    local count=0
    local batch=()
    local success_count=0
    local failure_count=0
    
    log_info "Starting log forwarding to Datadog"
    
    # Find unprocessed log files
    while IFS= read -r log_file; do
        # Check if already processed
        if grep -q "^$(realpath "$log_file")$" "$PROCESSED_LOGS_FILE" 2>/dev/null; then
            continue
        fi
        
        # Read log entries from JSONL file
        while IFS= read -r line; do
            if [[ -z "$line" ]] || [[ "$line" == "{}" ]]; then
                continue
            fi
            
            # Parse and enrich log entry
            local enriched_log
            enriched_log=$(jq -c \
                --arg source "goose" \
                --arg service "goose-scripts" \
                '. + {
                    ddsource: $source,
                    service: $service,
                    host: .hostname,
                    env: "production"
                }' <<< "$line" 2>/dev/null)
            
            if [[ -n "$enriched_log" ]]; then
                batch+=("$enriched_log")
                ((count++)) || true
                
                # Send batch when it reaches BATCH_SIZE
                if [[ ${#batch[@]} -ge $BATCH_SIZE ]]; then
                    if send_log_batch "${batch[@]}"; then
                        ((success_count += ${#batch[@]})) || true
                    else
                        ((failure_count += ${#batch[@]})) || true
                    fi
                    batch=()
                fi
            fi
        done < "$log_file"
        
        # Mark file as processed
        echo "$(realpath "$log_file")" >> "$PROCESSED_LOGS_FILE"
    done < <(find "$LOG_DIR" -name "*.jsonl" -type f -mmin +1 2>/dev/null | head -100)
    
    # Send remaining batch
    if [[ ${#batch[@]} -gt 0 ]]; then
        if send_log_batch "${batch[@]}"; then
            ((success_count += ${#batch[@]})) || true
        else
            ((failure_count += ${#batch[@]})) || true
        fi
    fi
    
    # Record metrics
    record_metric "logs_processed" "$count"
    record_metric "logs_success" "$success_count"
    record_metric "logs_failure" "$failure_count"
    increment_counter "log_forward_cycles"
    
    if [[ $count -gt 0 ]]; then
        log_info "Forwarded $count log entries to Datadog" "success=$success_count" "failure=$failure_count"
    else
        log_debug "No new log entries to forward"
    fi
    
    end_span
}

# Function to send log batch to Datadog
send_log_batch() {
    local batch_size=${#@}
    local batch_json
    batch_json=$(printf '%s\n' "$@" | jq -s '.')
    
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$DD_LOGS_ENDPOINT/${DD_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$batch_json" 2>&1)
    
    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | head -n-1)
    
    if [[ "$http_code" != "200" ]]; then
        log_warn "Failed to forward log batch to Datadog" "http_code=$http_code" "batch_size=$batch_size" "error=$body"
        increment_counter "log_batch_failures"
        return 1
    fi
    
    log_debug "Successfully forwarded log batch" "batch_size=$batch_size"
    increment_counter "log_batch_successes"
    return 0
}

# Function to forward metrics to Datadog
forward_metrics() {
    start_span "forward_metrics"
    local forward_start_time=$(date +%s.%N)
    local count=0
    local success_count=0
    local failure_count=0
    
    log_info "Starting metrics forwarding to Datadog"
    
    # Find unprocessed metrics files
    while IFS= read -r metrics_file; do
        # Check if already processed
        if grep -q "^$(realpath "$metrics_file")$" "$PROCESSED_METRICS_FILE" 2>/dev/null; then
            continue
        fi
        
        # Read metrics JSON
        local metrics_json
        metrics_json=$(cat "$metrics_file" 2>/dev/null || echo "{}")
        
        if [[ -z "$metrics_json" ]] || [[ "$metrics_json" == "{}" ]]; then
            continue
        fi
        
        # Extract script name
        local script_name
        script_name=$(basename "$metrics_file" | sed 's/-metrics-.*//')
        
        # Extract timestamp
        local timestamp
        timestamp=$(jq -r '.start_time // empty' <<< "$metrics_json" 2>/dev/null || echo "")
        if [[ -z "$timestamp" ]]; then
            timestamp=$(date +%s)
        else
            # Convert to Unix timestamp if needed
            if [[ "$timestamp" =~ ^[0-9]+\.[0-9]+$ ]]; then
                timestamp=$(printf "%.0f" "$timestamp")
            fi
        fi
        
        # Build Datadog metrics payload
        local series
        series=$(jq -c --arg script "$script_name" --arg timestamp "$timestamp" '
            to_entries |
            map(select(.value != null and .value != "" and .value != "unknown")) |
            map({
                metric: "goose." + (.key | gsub("[^a-zA-Z0-9_]"; "_") | ascii_downcase),
                points: [[($timestamp | tonumber), (.value | tonumber? // 0)]],
                tags: ["script:" + $script],
                type: "gauge"
            })
        ' <<< "$metrics_json" 2>/dev/null)
        
        if [[ -n "$series" ]] && [[ "$series" != "[]" ]]; then
            local payload
            payload=$(jq -n --argjson series "$series" '{series: $series}')
            
            # Send to Datadog
            local response
            response=$(curl -s -w "\n%{http_code}" \
                -X POST "$DD_METRICS_ENDPOINT?api_key=${DD_API_KEY}" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>&1)
            
            local http_code
            http_code=$(echo "$response" | tail -n1)
            local body
            body=$(echo "$response" | head -n-1)
            
            if [[ "$http_code" == "202" ]] || [[ "$http_code" == "200" ]]; then
                echo "$(realpath "$metrics_file")" >> "$PROCESSED_METRICS_FILE"
                ((count++)) || true
                ((success_count++)) || true
                log_debug "Successfully forwarded metrics file" "file=$(basename "$metrics_file")"
            else
                ((failure_count++)) || true
                log_warn "Failed to forward metrics file" "file=$(basename "$metrics_file")" "http_code=$http_code" "error=$body"
            fi
        fi
    done < <(find "$METRICS_DIR" -name "*-metrics-*.json" -type f -mmin +1 2>/dev/null | head -100)
    
    # Calculate forwarding latency
    local forward_end_time=$(date +%s.%N)
    local forward_latency
    if command -v bc &> /dev/null; then
        forward_latency=$(echo "$forward_end_time - $forward_start_time" | bc -l 2>/dev/null || echo "0")
    else
        forward_latency=$(awk "BEGIN {printf \"%.3f\", $forward_end_time - $forward_start_time}" 2>/dev/null || echo "0")
    fi
    
    # Record metrics
    record_metric "metrics_files_processed" "$count"
    record_metric "metrics_files_success" "$success_count"
    record_metric "metrics_files_failure" "$failure_count"
    record_metric "metrics_forward_latency_seconds" "$forward_latency"
    increment_counter "metrics_forward_cycles"
    
    if [[ $count -gt 0 ]]; then
        log_info "Forwarded metrics from $count files to Datadog" "success=$success_count" "failure=$failure_count" "latency=${forward_latency}s"
    else
        log_debug "No new metrics files to forward"
    fi
    
    end_span
}

# Main loop
main() {
    log_info "🚀 Starting Datadog forwarder..." \
        "api_key_prefix=${DD_API_KEY:0:8}..." \
        "site=$DD_SITE" \
        "log_dir=$LOG_DIR" \
        "metrics_dir=$METRICS_DIR" \
        "interval=${INTERVAL}s" \
        "forward_logs=$FORWARD_LOGS" \
        "forward_metrics=$FORWARD_METRICS"
    
    record_metric "forwarder_mode" "$([ "$FORWARD_LOGS" == "true" ] && echo "logs " || echo "")$([ "$FORWARD_METRICS" == "true" ] && echo "metrics" || echo "")"
    record_metric "dd_site" "$DD_SITE"
    record_metric "batch_size" "$BATCH_SIZE"
    record_metric "interval" "$INTERVAL"
    
    increment_counter "forwarder_starts"
    
    while true; do
        start_span "forwarder_cycle"
        
        if [[ "$FORWARD_LOGS" == "true" ]]; then
            forward_logs
        fi
        
        if [[ "$FORWARD_METRICS" == "true" ]]; then
            forward_metrics
        fi
        
        end_span
        sleep "$INTERVAL"
    done
}

# Handle signals
trap 'log_info "Shutting down..."; EXIT_CODE=0; exit 0' INT TERM

# Run main loop
main

