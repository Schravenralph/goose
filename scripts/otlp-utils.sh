#!/bin/bash

# OpenTelemetry OTLP utilities for bash scripts
# Provides functions to export traces and spans to OTLP-compatible backends

# OTLP configuration
OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-}"
OTLP_TIMEOUT="${OTEL_EXPORTER_OTLP_TIMEOUT:-10000}"
OTLP_ENABLED="${OTEL_EXPORTER_OTLP_ENABLED:-false}"

# Service resource attributes
OTLP_SERVICE_NAME="${OTEL_SERVICE_NAME:-goose-scripts}"
OTLP_SERVICE_VERSION="${OTEL_SERVICE_VERSION:-unknown}"
OTLP_SERVICE_NAMESPACE="${OTEL_SERVICE_NAMESPACE:-goose}"

# Internal state for span tracking
declare -A OTLP_SPANS
declare -A OTLP_SPAN_STARTS

# Initialize OTLP if endpoint is configured
init_otlp() {
    if [[ -z "$OTLP_ENDPOINT" ]]; then
        return 1
    fi
    
    # Validate endpoint URL
    if [[ ! "$OTLP_ENDPOINT" =~ ^https?:// ]]; then
        if command -v log_error &> /dev/null; then
            log_error "Invalid OTLP endpoint format: $OTLP_ENDPOINT (must start with http:// or https://)"
        fi
        return 1
    fi
    
    OTLP_ENABLED="true"
    if command -v log_debug &> /dev/null; then
        log_debug "OTLP initialized" "endpoint=$OTLP_ENDPOINT" "timeout=${OTLP_TIMEOUT}ms"
    fi
    return 0
}

# Convert trace ID to W3C Trace Context format (32 hex characters)
# Input can be UUID or any string, output is 32 hex characters
normalize_trace_id() {
    local trace_id="$1"
    
    # If already 32 hex chars, return as-is
    if [[ "$trace_id" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo "$trace_id" | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    
    # If it's a UUID (with dashes), remove dashes and pad/truncate to 32 chars
    local clean_id="${trace_id//-/}"
    
    # Take first 32 hex characters, pad if needed
    if [[ "$clean_id" =~ ^[0-9a-fA-F]+$ ]]; then
        local normalized
        normalized=$(echo "$clean_id" | head -c 32 | tr '[:upper:]' '[:lower:]')
        # Pad to 32 characters with zeros if needed
        printf "%-32s" "$normalized" | tr ' ' '0'
        return 0
    fi
    
    # Otherwise, hash it to get 32 hex chars
    if command -v sha256sum &> /dev/null; then
        echo -n "$trace_id" | sha256sum | cut -d' ' -f1 | head -c 32 | tr '[:upper:]' '[:lower:]'
    elif command -v shasum &> /dev/null; then
        echo -n "$trace_id" | shasum -a 256 | cut -d' ' -f1 | head -c 32 | tr '[:upper:]' '[:lower:]'
    else
        # Fallback: use md5 and pad/truncate
        if command -v md5sum &> /dev/null; then
            echo -n "$trace_id" | md5sum | cut -d' ' -f1 | head -c 32 | tr '[:upper:]' '[:lower:]'
        else
            # Last resort: simple hash simulation
            echo -n "$trace_id" | od -A n -t x1 | tr -d ' \n' | head -c 32 | tr '[:upper:]' '[:lower:]'
        fi
    fi
}

# Convert span ID to W3C Trace Context format (16 hex characters)
normalize_span_id() {
    local span_id="$1"
    
    # If already 16 hex chars, return as-is
    if [[ "$span_id" =~ ^[0-9a-fA-F]{16}$ ]]; then
        echo "$span_id" | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    
    # Hash to get 16 hex chars
    if command -v sha256sum &> /dev/null; then
        echo -n "$span_id" | sha256sum | cut -d' ' -f1 | head -c 16 | tr '[:upper:]' '[:lower:]'
    elif command -v shasum &> /dev/null; then
        echo -n "$span_id" | shasum -a 256 | cut -d' ' -f1 | head -c 16 | tr '[:upper:]' '[:lower:]'
    else
        if command -v md5sum &> /dev/null; then
            echo -n "$span_id" | md5sum | cut -d' ' -f1 | head -c 16 | tr '[:upper:]' '[:lower:]'
        else
            echo -n "$span_id" | od -A n -t x1 | tr -d ' \n' | head -c 16 | tr '[:upper:]' '[:lower:]'
        fi
    fi
}

# Get current time in nanoseconds since Unix epoch
get_nano_timestamp() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: date doesn't support nanoseconds, use seconds and pad
        date +%s000000000
    else
        # Linux: date supports nanoseconds
        date +%s%N
    fi
}

# Convert Unix timestamp with nanoseconds to OpenTelemetry format
timestamp_to_nanos() {
    local timestamp="$1"
    # If timestamp is already in nanoseconds format (has more than 10 digits), use as-is
    if [[ ${#timestamp} -gt 10 ]]; then
        echo "$timestamp"
    else
        # Assume seconds, convert to nanoseconds
        echo "${timestamp}000000000"
    fi
}

# Export a span to OTLP via HTTP
# This sends spans in a format compatible with OpenTelemetry Collector
export_span_to_otlp() {
    if [[ "$OTLP_ENABLED" != "true" ]] || [[ -z "$OTLP_ENDPOINT" ]]; then
        return 0
    fi
    
    local span_id="$1"
    local span_name="$2"
    local trace_id="$3"
    local parent_span_id="${4:-}"
    local start_time="${5:-}"
    local end_time="${6:-}"
    local status_code="${7:-OK}"
    local attributes="${8:-}"
    
    # Normalize IDs
    local normalized_trace_id
    normalized_trace_id=$(normalize_trace_id "$trace_id")
    local normalized_span_id
    normalized_span_id=$(normalize_span_id "$span_id")
    local normalized_parent_id=""
    if [[ -n "$parent_span_id" ]]; then
        normalized_parent_id=$(normalize_span_id "$parent_span_id")
    fi
    
    # Convert timestamps
    local start_nanos
    start_nanos=$(timestamp_to_nanos "${start_time:-$(get_nano_timestamp)}")
    local end_nanos
    end_nanos=$(timestamp_to_nanos "${end_time:-$(get_nano_timestamp)}")
    
    # Build OTLP payload
    # Note: This is a simplified JSON format that works with many OTLP collectors
    # Full OTLP uses protobuf, but collectors often accept JSON for convenience
    local payload
    if command -v jq &> /dev/null; then
        payload=$(jq -n \
            --arg trace_id "$normalized_trace_id" \
            --arg span_id "$normalized_span_id" \
            --arg parent_id "$normalized_parent_id" \
            --arg name "$span_name" \
            --arg start_time "$start_nanos" \
            --arg end_time "$end_nanos" \
            --arg status "$status_code" \
            --arg service_name "$OTLP_SERVICE_NAME" \
            --arg service_version "$OTLP_SERVICE_VERSION" \
            --arg service_namespace "$OTLP_SERVICE_NAMESPACE" \
            '{
                resourceSpans: [{
                    resource: {
                        attributes: [
                            { key: "service.name", value: { stringValue: $service_name } },
                            { key: "service.version", value: { stringValue: $service_version } },
                            { key: "service.namespace", value: { stringValue: $service_namespace } }
                        ]
                    },
                    scopeSpans: [{
                        spans: [{
                            traceId: $trace_id,
                            spanId: $span_id,
                            parentSpanId: ($parent_id | if . == "" then empty else . end),
                            name: $name,
                            kind: 1,
                            startTimeUnixNano: $start_time,
                            endTimeUnixNano: $end_time,
                            status: { code: (if $status == "ERROR" then 2 else 1 end) }
                        }]
                    }]
                }]
            }')
    else
        # Fallback without jq - create simple JSON
        local parent_json=""
        if [[ -n "$normalized_parent_id" ]]; then
            parent_json="\"parentSpanId\":\"$normalized_parent_id\","
        fi
        local status_code_num="1"
        if [[ "$status_code" == "ERROR" ]]; then
            status_code_num="2"
        fi
        payload="{"
        payload+="\"resourceSpans\":[{"
        payload+="\"resource\":{"
        payload+="\"attributes\":[{"
        payload+="\"key\":\"service.name\",\"value\":{\"stringValue\":\"$OTLP_SERVICE_NAME\"}"
        payload+="},{"
        payload+="\"key\":\"service.version\",\"value\":{\"stringValue\":\"$OTLP_SERVICE_VERSION\"}"
        payload+="},{"
        payload+="\"key\":\"service.namespace\",\"value\":{\"stringValue\":\"$OTLP_SERVICE_NAMESPACE\"}"
        payload+="}]"
        payload+="},"
        payload+="\"scopeSpans\":[{"
        payload+="\"spans\":[{"
        payload+="\"traceId\":\"$normalized_trace_id\","
        payload+="\"spanId\":\"$normalized_span_id\","
        payload+="$parent_json"
        payload+="\"name\":\"$span_name\","
        payload+="\"kind\":1,"
        payload+="\"startTimeUnixNano\":\"$start_nanos\","
        payload+="\"endTimeUnixNano\":\"$end_nanos\","
        payload+="\"status\":{\"code\":$status_code_num}"
        payload+="}]"
        payload+="}]"
        payload+="}]"
        payload+="}"
    fi
    
    # Determine OTLP endpoint URL
    # OTLP HTTP endpoint for traces is typically /v1/traces
    local otlp_url="$OTLP_ENDPOINT"
    if [[ ! "$otlp_url" =~ /v1/traces$ ]] && [[ ! "$otlp_url" =~ /traces$ ]]; then
        # Append /v1/traces if not already present
        otlp_url="${OTLP_ENDPOINT%/}/v1/traces"
    fi
    
    # Send via curl
    local timeout_sec=$((OTLP_TIMEOUT / 1000))
    if [[ $timeout_sec -lt 1 ]]; then
        timeout_sec=1
    fi
    
    if command -v curl &> /dev/null; then
        local response
        response=$(curl -s -w "\n%{http_code}" \
            --max-time "$timeout_sec" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$otlp_url" 2>/dev/null)
        
        local http_code
        http_code=$(echo "$response" | tail -n1)
        
        if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
            if command -v log_debug &> /dev/null; then
                log_debug "OTLP span exported successfully" "span=$span_name" "trace_id=$normalized_trace_id"
            fi
            return 0
        else
            if command -v log_warn &> /dev/null; then
                log_warn "OTLP export failed" "http_code=$http_code" "span=$span_name"
            fi
            return 1
        fi
    else
        if command -v log_warn &> /dev/null; then
            log_warn "curl not available, cannot export to OTLP"
        fi
        return 1
    fi
}

# Track span start for OTLP export
otlp_start_span() {
    local span_id="$1"
    local span_name="$2"
    local trace_id="${3:-$TRACE_ID}"
    local parent_span_id="${4:-${SPAN_ID:-}}"
    
    # Store span information
    OTLP_SPANS["$span_id"]="$span_name|$trace_id|$parent_span_id"
    OTLP_SPAN_STARTS["$span_id"]=$(get_nano_timestamp)
}

# Track span end and export to OTLP
otlp_end_span() {
    local span_id="$1"
    local status="${2:-OK}"
    
    if [[ -z "${OTLP_SPANS[$span_id]:-}" ]]; then
        return 1
    fi
    
    # Parse stored span info
    local span_info="${OTLP_SPANS[$span_id]}"
    local span_name
    span_name=$(echo "$span_info" | cut -d'|' -f1)
    local trace_id
    trace_id=$(echo "$span_info" | cut -d'|' -f2)
    local parent_span_id
    parent_span_id=$(echo "$span_info" | cut -d'|' -f3)
    
    local start_time="${OTLP_SPAN_STARTS[$span_id]}"
    local end_time
    end_time=$(get_nano_timestamp)
    
    # Export to OTLP
    export_span_to_otlp "$span_id" "$span_name" "$trace_id" "$parent_span_id" "$start_time" "$end_time" "$status"
    
    # Clean up
    unset OTLP_SPANS["$span_id"]
    unset OTLP_SPAN_STARTS["$span_id"]
}

# Export W3C Trace Context for propagation
# Returns traceparent header value in format: 00-<trace-id>-<span-id>-<flags>
export_trace_context() {
    local trace_id="${1:-$TRACE_ID}"
    local span_id="${2:-${SPAN_ID:-}}"
    
    if [[ -z "$trace_id" ]] || [[ -z "$span_id" ]]; then
        return 1
    fi
    
    local normalized_trace_id
    normalized_trace_id=$(normalize_trace_id "$trace_id")
    local normalized_span_id
    normalized_span_id=$(normalize_span_id "$span_id")
    
    # W3C Trace Context format: version-trace_id-parent_id-flags
    # version: 00 (2 hex chars)
    # trace_id: 32 hex chars
    # parent_id/span_id: 16 hex chars
    # flags: 01 (sampled) or 00 (not sampled)
    echo "00-$normalized_trace_id-$normalized_span_id-01"
}

# Import W3C Trace Context and set TRACE_ID and PARENT_SPAN_ID
# Accepts traceparent header value
import_trace_context() {
    local traceparent="$1"
    
    if [[ -z "$traceparent" ]]; then
        return 1
    fi
    
    # Parse traceparent: 00-<trace-id>-<span-id>-<flags>
    if [[ ! "$traceparent" =~ ^00-([0-9a-fA-F]{32})-([0-9a-fA-F]{16})-([0-9a-fA-F]{2})$ ]]; then
        if command -v log_warn &> /dev/null; then
            log_warn "Invalid traceparent format: $traceparent"
        fi
        return 1
    fi
    
    local imported_trace_id="${BASH_REMATCH[1]}"
    local imported_span_id="${BASH_REMATCH[2]}"
    
    # Set as parent span ID and use imported trace ID
    export PARENT_SPAN_ID="$imported_span_id"
    export TRACE_ID="$imported_trace_id"
    
    if command -v log_debug &> /dev/null; then
        log_debug "Imported trace context" "trace_id=$imported_trace_id" "parent_span_id=$imported_span_id"
    fi
    
    return 0
}

# Export trace context as environment variable for child processes
export_trace_context_env() {
    local traceparent
    traceparent=$(export_trace_context)
    
    if [[ -z "$traceparent" ]]; then
        return 1
    fi
    
    export TRACEPARENT="$traceparent"
    if command -v log_debug &> /dev/null; then
        log_debug "Exported TRACEPARENT environment variable" "traceparent=$traceparent"
    fi
}

# Import trace context from environment variable
import_trace_context_env() {
    if [[ -n "${TRACEPARENT:-}" ]]; then
        import_trace_context "$TRACEPARENT"
    fi
}

# Auto-initialize OTLP if endpoint is configured and logging-utils is loaded
if [[ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]] && [[ "${OTEL_EXPORTER_OTLP_ENABLED:-}" != "false" ]]; then
    init_otlp || true
fi

# Auto-import trace context from environment if available
import_trace_context_env || true

