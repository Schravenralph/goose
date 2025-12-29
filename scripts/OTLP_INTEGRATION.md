# OpenTelemetry (OTLP) Integration for Bash Scripts

This document describes how to use OpenTelemetry Protocol (OTLP) integration with bash scripts in the Goose project.

## Overview

The OTLP integration allows bash scripts to export traces and spans to OpenTelemetry-compatible observability backends (e.g., Jaeger, Tempo, Grafana Cloud, etc.). This enables distributed tracing across scripts and services.

## Features

- **Automatic Span Export**: Spans created with `start_span()` and `end_span()` are automatically exported to OTLP if configured
- **W3C Trace Context Compatibility**: Trace IDs and span IDs are normalized to W3C Trace Context format
- **Span Context Propagation**: Support for propagating trace context between scripts via environment variables
- **Parent-Child Span Relationships**: Nested spans are correctly linked to their parent spans

## Prerequisites

1. An OpenTelemetry-compatible backend:
   - [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
   - [Jaeger](https://www.jaegertracing.io/) (with OTLP receiver)
   - [Grafana Tempo](https://grafana.com/oss/tempo/)
   - [Grafana Cloud](https://grafana.com/products/cloud/)
   - Any OTLP-compatible observability platform

2. Required tools (usually pre-installed):
   - `curl` - for HTTP requests to OTLP endpoint
   - `jq` (optional) - for JSON formatting (fallback available)

## Configuration

### Environment Variables

Set these environment variables to enable OTLP export:

```bash
# Required: OTLP endpoint URL
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"

# Optional: Timeout in milliseconds (default: 10000)
export OTEL_EXPORTER_OTLP_TIMEOUT=10000

# Optional: Enable OTLP export (default: auto-enabled if endpoint is set)
export OTEL_EXPORTER_OTLP_ENABLED=true

# Optional: Service attributes
export OTEL_SERVICE_NAME="goose-scripts"
export OTEL_SERVICE_VERSION="1.0.0"
export OTEL_SERVICE_NAMESPACE="goose"
```

### OTLP Endpoint URLs

The endpoint URL should point to your OTLP receiver:

- **OpenTelemetry Collector**: `http://localhost:4318` (HTTP) or `http://localhost:4317` (gRPC)
- **Jaeger**: `http://localhost:4318/v1/traces` (if OTLP receiver enabled)
- **Grafana Cloud**: `https://tempo-us-central1.grafana.net:443`
- **Custom endpoint**: `http://your-otel-collector:4318`

If the URL doesn't end with `/v1/traces`, it will be automatically appended.

## Usage

### Basic Usage

Simply source `logging-utils.sh` (which automatically loads `otlp-utils.sh`) and use spans as normal:

```bash
#!/bin/bash

source "$(dirname "$0")/logging-utils.sh"

# Set OTLP endpoint
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"

# Start a span
start_span "my_operation"

# Do some work
sleep 2
log_info "Doing work..."

# End the span (automatically exported to OTLP)
end_span
```

### Nested Spans

Nested spans are automatically linked to their parent:

```bash
start_span "parent_operation"

start_span "child_operation"
# This span will have parent_operation as its parent
end_span

end_span
```

### Span Context Propagation

To propagate trace context between scripts or processes:

**Exporting context (parent script):**

```bash
#!/bin/bash
source "$(dirname "$0")/logging-utils.sh"

start_span "parent_script"

# Export trace context for child processes
export_trace_context_env

# Execute child script (inherits TRACEPARENT)
./child-script.sh

end_span
```

**Importing context (child script):**

```bash
#!/bin/bash
source "$(dirname "$0")/logging-utils.sh"

# Import trace context from environment
import_trace_context_env

# This span will be linked to the parent trace
start_span "child_script"
end_span
```

### Manual Span Export

You can manually export spans using the OTLP functions:

```bash
source "$(dirname "$0")/otlp-utils.sh"

# Initialize OTLP
init_otlp

# Track span start
otlp_start_span "span-123" "my_span" "$TRACE_ID" "$PARENT_SPAN_ID"

# ... do work ...

# Export span end
otlp_end_span "span-123" "OK"
```

### Error Status

Spans are automatically marked as ERROR if the script exits with a non-zero code:

```bash
start_span "operation"
# ... do work that might fail ...
if [[ $? -ne 0 ]]; then
    # Span will be marked as ERROR when end_span is called
    exit 1
fi
end_span
```

Or manually set status:

```bash
otlp_end_span "span-123" "ERROR"
```

## Trace ID Format

Trace IDs are automatically normalized to W3C Trace Context format (32 hexadecimal characters). The integration supports:

- UUID format: `a1b2c3d4-e5f6-7890-abcd-ef1234567890` → normalized to 32 hex chars
- Hash-based IDs: Any string is hashed to produce a 32-char hex ID
- Existing 32-char hex IDs: Used as-is

## W3C Trace Context

The integration supports W3C Trace Context propagation via the `TRACEPARENT` environment variable:

```
TRACEPARENT=00-<trace-id>-<span-id>-<flags>
```

Functions available:
- `export_trace_context()` - Returns traceparent header value
- `import_trace_context()` - Imports traceparent value
- `export_trace_context_env()` - Sets TRACEPARENT environment variable
- `import_trace_context_env()` - Imports from TRACEPARENT environment variable

## Integration with Rust Services

The bash script trace IDs are compatible with the Rust OpenTelemetry implementation. When a bash script exports a trace, it can be correlated with traces from Rust services if they use the same trace ID.

To share trace context between bash scripts and Rust services:

1. **From Bash to Rust**: Export `TRACEPARENT` environment variable and pass it to Rust service
2. **From Rust to Bash**: Rust service should set `TRACEPARENT` environment variable that bash scripts can import

Example:

```bash
#!/bin/bash
source "$(dirname "$0")/logging-utils.sh"

start_span "bash_operation"
export_trace_context_env

# Call Rust CLI that respects TRACEPARENT
./target/debug/goose session

end_span
```

## Testing

### Test OTLP Export

1. Start an OpenTelemetry Collector or test receiver:

```bash
# Using OpenTelemetry Collector
docker run -p 4318:4318 -v $(pwd)/otel-collector-config.yaml:/etc/otel-collector-config.yaml otel/opentelemetry-collector:latest --config=/etc/otel-collector-config.yaml
```

2. Configure a test script:

```bash
#!/bin/bash
source "$(dirname "$0")/logging-utils.sh"

export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"

start_span "test_operation"
log_info "Testing OTLP export"
sleep 1
end_span
```

3. Check your observability backend for the exported spans.

### Test with Jaeger

1. Start Jaeger with OTLP receiver:

```bash
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4317:4317 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

2. Export to Jaeger:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
# Run your script
```

3. View traces at `http://localhost:16686`

## Troubleshooting

### Spans Not Appearing in Backend

1. **Check OTLP endpoint is accessible:**
   ```bash
   curl -v http://localhost:4318/v1/traces
   ```

2. **Enable debug logging:**
   ```bash
   export OTEL_EXPORTER_OTLP_ENABLED=true
   # Scripts will log OTLP export attempts
   ```

3. **Check curl is available:**
   ```bash
   command -v curl
   ```

4. **Verify trace IDs are normalized:**
   ```bash
   source "$(dirname "$0")/otlp-utils.sh"
   normalize_trace_id "test-trace-id"
   # Should output 32 hex characters
   ```

### HTTP Errors

- **404 Not Found**: Check endpoint URL includes `/v1/traces` or ensure collector is configured correctly
- **Timeout**: Increase `OTEL_EXPORTER_OTLP_TIMEOUT` value
- **Connection Refused**: Verify OTLP receiver is running and accessible

## Implementation Notes

- The implementation uses OTLP HTTP/JSON format, which is supported by most OpenTelemetry Collectors
- Full OTLP protobuf encoding is not implemented (would require protobuf compiler)
- Spans are exported synchronously at span end time
- Trace IDs and span IDs are normalized to W3C Trace Context format for compatibility
- Parent-child relationships are preserved for nested spans

## Related Documentation

- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [Goose Logging Utilities](./LOGGING_IMPROVEMENTS.md)
- [Goose Monitoring Integration](./MONITORING_INTEGRATION.md)

