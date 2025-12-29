#!/bin/bash

# Prometheus exporter for Goose metrics
# Converts JSON metrics files to Prometheus format and serves them via HTTP
# Usage: ./prometheus-exporter.sh [--port PORT] [--metrics-dir DIR]

set -euo pipefail

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
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq first."
    exit 1
fi

# Ensure metrics directory exists
mkdir -p "$METRICS_DIR"

# Function to convert JSON metrics to Prometheus format
convert_metrics_to_prometheus() {
    local metrics_file="$1"
    
    if [[ ! -f "$metrics_file" ]]; then
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
    local output=""
    
    # Find all metrics files
    local metrics_files
    mapfile -t metrics_files < <(find "$METRICS_DIR" -name "*-metrics-*.json" -type f -mtime -7 2>/dev/null | sort)
    
    if [[ ${#metrics_files[@]} -eq 0 ]]; then
        echo "# No metrics files found in $METRICS_DIR"
        return
    fi
    
    # Add Prometheus header
    output+="# HELP goose_script_metrics Goose script execution metrics\n"
    output+="# TYPE goose_script_metrics gauge\n"
    
    # Process each metrics file
    for metrics_file in "${metrics_files[@]}"; do
        local converted
        converted=$(convert_metrics_to_prometheus "$metrics_file")
        if [[ -n "$converted" ]]; then
            output+="$converted\n"
        fi
    done
    
    # Add summary metrics
    local total_files=${#metrics_files[@]}
    output+="goose_metrics_files_total{dir=\"$METRICS_DIR\"} $total_files\n"
    
    echo -e "$output"
}

# Function to handle HTTP request
handle_request() {
    local method="$1"
    local path="$2"
    
    if [[ "$method" == "GET" ]] && [[ "$path" == "/metrics" ]]; then
        # Serve Prometheus metrics
        echo "HTTP/1.1 200 OK"
        echo "Content-Type: text/plain; version=0.0.4"
        echo ""
        aggregate_all_metrics
    elif [[ "$method" == "GET" ]] && [[ "$path" == "/" ]]; then
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
        # 404 Not Found
        echo "HTTP/1.1 404 Not Found"
        echo "Content-Type: text/plain"
        echo ""
        echo "Not Found"
    fi
}

# Function to start HTTP server
start_server() {
    echo "🚀 Starting Goose Prometheus Exporter..."
    echo "   Port: $PORT"
    echo "   Metrics Directory: $METRICS_DIR"
    echo "   Metrics Endpoint: http://localhost:$PORT/metrics"
    echo ""
    
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
        echo "Warning: Using netcat. Consider installing socat for better reliability."
        while true; do
            {
                read -r request
                method=$(echo "$request" | awk '{print $1}')
                path=$(echo "$request" | awk '{print $2}')
                handle_request "$method" "$path"
            } < <(nc -l -p "$PORT" 2>/dev/null || true)
        done
    else
        echo "Error: Neither socat nor netcat is available. Please install one of them."
        echo "  Ubuntu/Debian: sudo apt-get install socat"
        echo "  macOS: brew install socat"
        exit 1
    fi
}

# Check if port is already in use
if command -v lsof &> /dev/null; then
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "Error: Port $PORT is already in use"
        exit 1
    fi
fi

# Start the server
start_server

