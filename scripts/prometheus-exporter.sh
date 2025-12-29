#!/bin/bash

# Prometheus exporter for Goose metrics
# Converts JSON metrics files to Prometheus format and serves them via HTTP
# Usage: ./prometheus-exporter.sh [--port PORT] [--metrics-dir DIR]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="prometheus-exporter"

# Source logging utilities
source "$SCRIPT_DIR/logging-utils.sh"

# Default configuration
PORT="${PROMETHEUS_EXPORTER_PORT:-9090}"
METRICS_DIR="${PROMETHEUS_METRICS_DIR:-/tmp/goose-logs}"
SCRAPE_INTERVAL="${PROMETHEUS_SCRAPE_INTERVAL:-30}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        --metrics-dir)
            METRICS_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--port PORT] [--metrics-dir DIR]"
            echo ""
            echo "Environment variables:"
            echo "  PROMETHEUS_EXPORTER_PORT     - Port to listen on (default: 9090)"
            echo "  PROMETHEUS_METRICS_DIR       - Directory containing metrics JSON files (default: /tmp/goose-logs)"
            echo "  PROMETHEUS_SCRAPE_INTERVAL   - Scrape interval in seconds (default: 30)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check dependencies
if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed. Please install jq first."
    exit 1
fi

# Ensure metrics directory exists
mkdir -p "$METRICS_DIR"
log_info "Metrics directory: $METRICS_DIR"

# Function to convert JSON metrics to Prometheus format
convert_metrics_to_prometheus() {
    local metrics_file="$1"
    
    if [[ ! -f "$metrics_file" ]]; then
        log_debug "Metrics file not found" "file=$metrics_file"
        return
    fi
    
    # Read JSON metrics
    local json_content
    json_content=$(cat "$metrics_file" 2>/dev/null || echo "{}")
    
    # Skip empty files
    if [[ -z "$json_content" ]] || [[ "$json_content" == "{}" ]]; then
        return
    fi
    
    # Extract script name from filename (format: script-metrics-*.json)
    local script_name
    script_name=$(basename "$metrics_file" | sed 's/-metrics-.*//')
    
    # Extract timestamp from filename
    local timestamp
    timestamp=$(basename "$metrics_file" | sed -n 's/.*-metrics-\([0-9]\{8\}_[0-9]\{6\}\).*/\1/p')
    
    # Convert timestamp to Unix timestamp for Prometheus
    local unix_timestamp
    if [[ -n "$timestamp" ]]; then
        unix_timestamp=$(date -d "${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2}" +%s 2>/dev/null || echo "")
    fi
    
    # Parse JSON and convert to Prometheus format
    # Prometheus format: metric_name{label1="value1",label2="value2"} value timestamp
    jq -r --arg script "$script_name" --arg timestamp "${unix_timestamp:-}" '
        to_entries[] |
        select(.value != null and .value != "" and .value != "unknown") |
        # Convert metric name to Prometheus format (lowercase, underscores)
        (.key | gsub("[^a-zA-Z0-9_]"; "_") | ascii_downcase) as $metric_name |
        # Determine metric type and format
        if (.value | type == "number" or (.value | test("^[0-9]+\\.?[0-9]*$"))) then
            # Numeric value
            "goose_\($metric_name){script=\"\($script)\"} \(.value)\(if $timestamp != "" then " \($timestamp)000" else "" end)"
        elif (.value | type == "string") then
            # String value - convert to info metric
            "goose_\($metric_name)_info{script=\"\($script)\",value=\"\(.value | gsub("\""; "\\\""))\"} 1\(if $timestamp != "" then " \($timestamp)000" else "" end)"
        else
            empty
        end
    ' <<< "$json_content" 2>/dev/null || true
}

# Function to aggregate all metrics
aggregate_all_metrics() {
    start_span "aggregate_metrics"
    local export_start_time=$(date +%s.%N)
    local output=""
    local files_processed=0
    local metrics_count=0
    
    # Find all metrics files
    local metrics_files
    mapfile -t metrics_files < <(find "$METRICS_DIR" -name "*-metrics-*.json" -type f -mtime -7 2>/dev/null | sort)
    
    if [[ ${#metrics_files[@]} -eq 0 ]]; then
        log_debug "No metrics files found" "dir=$METRICS_DIR"
        echo "# No metrics files found in $METRICS_DIR"
        end_span
        return
    fi
    
    log_debug "Aggregating metrics" "file_count=${#metrics_files[@]}"
    
    # Add Prometheus header
    output+="# HELP goose_script_metrics Goose script execution metrics\n"
    output+="# TYPE goose_script_metrics gauge\n"
    
    # Process each metrics file
    for metrics_file in "${metrics_files[@]}"; do
        local converted
        converted=$(convert_metrics_to_prometheus "$metrics_file")
        if [[ -n "$converted" ]]; then
            output+="$converted\n"
            ((files_processed++)) || true
            # Count metrics in the converted output (rough estimate)
            local metric_lines
            metric_lines=$(echo -e "$converted" | grep -c "^goose_" || echo "0")
            ((metrics_count += metric_lines)) || true
        fi
    done
    
    # Add summary metrics
    local total_files=${#metrics_files[@]}
    output+="goose_metrics_files_total{dir=\"$METRICS_DIR\"} $total_files\n"
    
    # Calculate export latency
    local export_end_time=$(date +%s.%N)
    local export_latency
    if command -v bc &> /dev/null; then
        export_latency=$(echo "$export_end_time - $export_start_time" | bc -l 2>/dev/null || echo "0")
    else
        export_latency=$(awk "BEGIN {printf \"%.3f\", $export_end_time - $export_start_time}" 2>/dev/null || echo "0")
    fi
    
    # Record metrics
    record_metric "export_files_processed" "$files_processed"
    record_metric "export_metrics_count" "$metrics_count"
    record_metric "export_latency_seconds" "$export_latency"
    increment_counter "export_cycles"
    
    log_info "Exported metrics" "files=$files_processed" "metrics=$metrics_count" "latency=${export_latency}s"
    
    echo -e "$output"
    end_span
}

# Function to handle HTTP request
handle_request() {
    local method="$1"
    local path="$2"
    
    increment_counter "http_requests"
    
    if [[ "$method" == "GET" ]] && [[ "$path" == "/metrics" ]]; then
        start_span "serve_metrics"
        increment_counter "metrics_endpoint_requests"
        log_debug "Serving Prometheus metrics endpoint"
        
        # Serve Prometheus metrics
        echo "HTTP/1.1 200 OK"
        echo "Content-Type: text/plain; version=0.0.4"
        echo ""
        aggregate_all_metrics
        
        end_span
    elif [[ "$method" == "GET" ]] && [[ "$path" == "/" ]]; then
        increment_counter "status_page_requests"
        log_debug "Serving status page"
        
        # Serve simple status page
        echo "HTTP/1.1 200 OK"
        echo "Content-Type: text/html"
        echo ""
        cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Goose Prometheus Exporter</title>
    <style>
        body { font-family: monospace; padding: 20px; }
        h1 { color: #333; }
        .info { background: #f0f0f0; padding: 10px; border-radius: 4px; margin: 10px 0; }
    </style>
</head>
<body>
    <h1>🐦 Goose Prometheus Exporter</h1>
    <div class="info">
        <strong>Status:</strong> Running<br>
        <strong>Metrics Directory:</strong> $METRICS_DIR<br>
        <strong>Port:</strong> $PORT<br>
        <strong>Metrics Endpoint:</strong> <a href="/metrics">/metrics</a>
    </div>
    <p>Prometheus can scrape metrics from: <code>http://localhost:$PORT/metrics</code></p>
</body>
</html>
EOF
    else
        increment_counter "http_404_errors"
        log_debug "404 Not Found" "path=$path"
        
        # 404 Not Found
        echo "HTTP/1.1 404 Not Found"
        echo "Content-Type: text/plain"
        echo ""
        echo "Not Found"
    fi
}

# Function to start HTTP server
start_server() {
    log_info "🚀 Starting Goose Prometheus Exporter..." \
        "port=$PORT" \
        "metrics_dir=$METRICS_DIR" \
        "metrics_endpoint=http://localhost:$PORT/metrics"
    
    record_metric "exporter_port" "$PORT"
    record_metric "metrics_directory" "$METRICS_DIR"
    increment_counter "exporter_starts"
    
    # Use netcat or socat for simple HTTP server
    if command -v socat &> /dev/null; then
        while true; do
            socat -T 1 TCP-LISTEN:$PORT,reuseaddr,fork SYSTEM:"
                read request
                method=\$(echo \$request | awk '{print \$1}')
                path=\$(echo \$request | awk '{print \$2}')
                $(declare -f handle_request aggregate_all_metrics convert_metrics_to_prometheus)
                handle_request \"\$method\" \"\$path\"
            "
        done
    elif command -v nc &> /dev/null; then
        # Fallback to netcat (less reliable)
        log_warn "Using netcat. Consider installing socat for better reliability."
        while true; do
            {
                read -r request
                method=$(echo "$request" | awk '{print $1}')
                path=$(echo "$request" | awk '{print $2}')
                handle_request "$method" "$path"
            } < <(nc -l -p "$PORT" 2>/dev/null || true)
        done
    else
        log_error "Neither socat nor netcat is available. Please install one of them."
        log_error "  Ubuntu/Debian: sudo apt-get install socat"
        log_error "  macOS: brew install socat"
        exit 1
    fi
}

# Check if port is already in use
if command -v lsof &> /dev/null; then
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        log_error "Port $PORT is already in use"
        exit 1
    fi
fi

# Record configuration metrics
record_metric "exporter_port" "$PORT"
record_metric "metrics_directory" "$METRICS_DIR"
record_metric "scrape_interval" "$SCRAPE_INTERVAL"

# Start the server
log_info "Starting Prometheus exporter" "port=$PORT" "metrics_dir=$METRICS_DIR"
start_server
