#!/bin/bash

# Validation script for monitoring tool deployment
# Checks that all deployed integrations are working correctly
# Usage: ./validate-monitoring-deployment.sh [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="validate-monitoring-deployment"

# Source logging utilities
source "$SCRIPT_DIR/logging-utils.sh"

VERBOSE=false
LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
METRICS_DIR="${METRICS_DIR:-/tmp/goose-logs}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--verbose]"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Track validation results
PASSED=0
FAILED=0
WARNINGS=0

# Function to record test result
record_result() {
    local test_name="$1"
    local status="$2"  # pass, fail, warn
    local message="$3"
    
    case "$status" in
        pass)
            ((PASSED++)) || true
            log_info "✓ PASS: $test_name" "$message"
            ;;
        fail)
            ((FAILED++)) || true
            log_error "✗ FAIL: $test_name" "$message"
            ;;
        warn)
            ((WARNINGS++)) || true
            log_warn "⚠ WARN: $test_name" "$message"
            ;;
    esac
}

# Function to check if service is running
check_service() {
    local service_name="$1"
    local display_name="${2:-$service_name}"
    
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        record_result "$display_name service" "pass" "Service is running"
        return 0
    elif systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        record_result "$display_name service" "warn" "Service is enabled but not running"
        return 1
    else
        record_result "$display_name service" "fail" "Service is not running or not installed"
        return 1
    fi
}

# Function to check HTTP endpoint
check_endpoint() {
    local url="$1"
    local name="$2"
    local expected_code="${3:-200}"
    
    local response_code
    response_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    
    if [[ "$response_code" == "$expected_code" ]]; then
        record_result "$name endpoint" "pass" "Responding with HTTP $response_code"
        return 0
    else
        record_result "$name endpoint" "fail" "Expected HTTP $expected_code, got $response_code"
        return 1
    fi
}

# Function to check if logs/metrics exist
check_data_files() {
    local dir="$1"
    local pattern="$2"
    local name="$3"
    
    local count
    count=$(find "$dir" -name "$pattern" -type f -mtime -1 2>/dev/null | wc -l)
    
    if [[ $count -gt 0 ]]; then
        record_result "$name data files" "pass" "Found $count files matching $pattern"
        return 0
    else
        record_result "$name data files" "warn" "No files found matching $pattern (may be normal if no scripts have run)"
        return 1
    fi
}

log_info "🔍 Starting monitoring deployment validation..."

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v curl &> /dev/null; then
    record_result "curl command" "fail" "curl is not installed"
else
    record_result "curl command" "pass" "curl is available"
fi

if ! command -v jq &> /dev/null; then
    record_result "jq command" "fail" "jq is not installed"
else
    record_result "jq command" "pass" "jq is available"
fi

# Check log/metrics directories
log_info "Checking data directories..."

if [[ -d "$LOG_DIR" ]]; then
    record_result "Log directory" "pass" "Directory exists: $LOG_DIR"
    check_data_files "$LOG_DIR" "*.jsonl" "Log"
else
    record_result "Log directory" "warn" "Directory does not exist: $LOG_DIR"
fi

if [[ -d "$METRICS_DIR" ]]; then
    record_result "Metrics directory" "pass" "Directory exists: $METRICS_DIR"
    check_data_files "$METRICS_DIR" "*-metrics-*.json" "Metrics"
else
    record_result "Metrics directory" "warn" "Directory does not exist: $METRICS_DIR"
fi

# Check Prometheus exporter
log_info "Checking Prometheus exporter..."

if check_service "goose-prometheus-exporter" "Prometheus Exporter"; then
    # Check if exporter is responding
    if check_endpoint "http://localhost:9090/metrics" "Prometheus Exporter"; then
        # Check if metrics are being exported
        local metrics_count
        metrics_count=$(curl -s http://localhost:9090/metrics 2>/dev/null | grep -c "^goose_" || echo "0")
        if [[ $metrics_count -gt 0 ]]; then
            record_result "Prometheus metrics export" "pass" "Exporting $metrics_count metrics"
        else
            record_result "Prometheus metrics export" "warn" "Exporter running but no metrics found"
        fi
    fi
else
    record_result "Prometheus exporter" "warn" "Service not running (may not be deployed)"
fi

# Check Prometheus server (if available)
log_info "Checking Prometheus server..."

if check_endpoint "http://localhost:9090/api/v1/status/config" "Prometheus Server" "200"; then
    # Check if Prometheus is scraping goose metrics
    local scrape_result
    scrape_result=$(curl -s "http://localhost:9090/api/v1/query?query=up{job=\"goose-metrics\"}" 2>/dev/null | jq -r '.data.result[0].value[1]' || echo "")
    if [[ "$scrape_result" == "1" ]]; then
        record_result "Prometheus scraping" "pass" "Prometheus is successfully scraping goose metrics"
    else
        record_result "Prometheus scraping" "warn" "Prometheus may not be configured to scrape goose metrics"
    fi
else
    record_result "Prometheus server" "warn" "Prometheus server not accessible (may not be deployed)"
fi

# Check Grafana (if available)
log_info "Checking Grafana..."

if check_endpoint "http://localhost:3000/api/health" "Grafana" "200"; then
    record_result "Grafana" "pass" "Grafana is accessible"
else
    record_result "Grafana" "warn" "Grafana not accessible (may not be deployed)"
fi

# Check Elasticsearch (if available)
log_info "Checking Elasticsearch..."

if check_endpoint "http://localhost:9200" "Elasticsearch" "200"; then
    # Check if goose logs index exists
    local index_exists
    index_exists=$(curl -s "http://localhost:9200/goose-logs-*" 2>/dev/null | jq -r '.error // empty' || echo "")
    if [[ -z "$index_exists" ]]; then
        record_result "Elasticsearch goose index" "pass" "Goose logs index exists or is accessible"
    else
        record_result "Elasticsearch goose index" "warn" "Goose logs index may not exist yet"
    fi
else
    record_result "Elasticsearch" "warn" "Elasticsearch not accessible (may not be deployed)"
fi

# Check Filebeat (if available)
log_info "Checking Filebeat..."

if check_service "filebeat" "Filebeat"; then
    # Check Filebeat status
    if command -v filebeat &> /dev/null; then
        local filebeat_status
        filebeat_status=$(sudo filebeat status 2>/dev/null | grep -i "running" || echo "")
        if [[ -n "$filebeat_status" ]]; then
            record_result "Filebeat status" "pass" "Filebeat is running"
        else
            record_result "Filebeat status" "warn" "Filebeat service exists but status unclear"
        fi
    fi
else
    record_result "Filebeat" "warn" "Filebeat not running (may not be deployed)"
fi

# Check Datadog forwarder
log_info "Checking Datadog forwarder..."

if check_service "goose-datadog-forwarder" "Datadog Forwarder"; then
    # Check recent logs for errors
    local recent_errors
    recent_errors=$(sudo journalctl -u goose-datadog-forwarder -n 20 --no-pager 2>/dev/null | grep -i "error\|fail" | wc -l || echo "0")
    if [[ $recent_errors -eq 0 ]]; then
        record_result "Datadog forwarder logs" "pass" "No recent errors in logs"
    else
        record_result "Datadog forwarder logs" "warn" "Found $recent_errors recent errors in logs"
    fi
else
    record_result "Datadog forwarder" "warn" "Service not running (may not be deployed or DD_API_KEY not set)"
fi

# Check Datadog API key (if forwarder is configured)
if systemctl is-enabled --quiet goose-datadog-forwarder 2>/dev/null; then
    if [[ -f /etc/goose-monitoring/datadog.env ]]; then
        if grep -q "DD_API_KEY=" /etc/goose-monitoring/datadog.env 2>/dev/null; then
            local api_key
            api_key=$(grep "DD_API_KEY=" /etc/goose-monitoring/datadog.env | cut -d'=' -f2 | tr -d ' ' || echo "")
            if [[ -n "$api_key" ]] && [[ "$api_key" != "your-api-key-here" ]]; then
                record_result "Datadog API key" "pass" "API key is configured"
            else
                record_result "Datadog API key" "fail" "API key is not properly configured"
            fi
        else
            record_result "Datadog API key" "fail" "API key not found in configuration"
        fi
    else
        record_result "Datadog API key" "warn" "Configuration file not found"
    fi
fi

# Summary
log_info "📊 Validation Summary"
log_info "  Passed: $PASSED"
log_info "  Failed: $FAILED"
log_info "  Warnings: $WARNINGS"

if [[ $FAILED -eq 0 ]]; then
    if [[ $WARNINGS -eq 0 ]]; then
        log_info "✅ All checks passed!"
        exit 0
    else
        log_info "⚠️  Some warnings, but no failures"
        exit 0
    fi
else
    log_error "❌ Some checks failed. Review the output above."
    exit 1
fi

