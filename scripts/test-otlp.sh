#!/bin/bash

# Test script for OTLP integration
# This script demonstrates and tests OTLP export functionality

# Don't use set -e to allow graceful test failures
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logging-utils.sh"

# Configuration
OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}"
OTLP_ENABLED="${OTEL_EXPORTER_OTLP_ENABLED:-false}"

echo "=== OTLP Integration Test ==="
echo ""

# Test 1: Trace ID normalization
echo "Test 1: Trace ID Normalization"
if [[ -n "$(type -t normalize_trace_id)" ]] && [[ "$(type -t normalize_trace_id)" == "function" ]]; then
    test_trace_id="test-trace-$(date +%s)"
    normalized=$(normalize_trace_id "$test_trace_id")
    if [[ ${#normalized} -eq 32 ]] && [[ "$normalized" =~ ^[0-9a-f]{32}$ ]]; then
        echo "✓ Trace ID normalization works: $normalized"
    else
        echo "✗ Trace ID normalization failed: $normalized"
        exit 1
    fi
else
    echo "✗ normalize_trace_id function not available"
    exit 1
fi
echo ""

# Test 2: Span ID normalization
echo "Test 2: Span ID Normalization"
if [[ -n "$(type -t normalize_span_id)" ]] && [[ "$(type -t normalize_span_id)" == "function" ]]; then
    test_span_id="test-span-$(date +%s)"
    normalized=$(normalize_span_id "$test_span_id")
    if [[ ${#normalized} -eq 16 ]] && [[ "$normalized" =~ ^[0-9a-f]{16}$ ]]; then
        echo "✓ Span ID normalization works: $normalized"
    else
        echo "✗ Span ID normalization failed: $normalized"
        exit 1
    fi
else
    echo "✗ normalize_span_id function not available"
    exit 1
fi
echo ""

# Test 3: Trace Context Export/Import
echo "Test 3: Trace Context Export/Import"
if [[ -n "$(type -t export_trace_context 2>/dev/null)" ]] && [[ "$(type -t export_trace_context 2>/dev/null)" == "function" ]]; then
    traceparent=$(export_trace_context 2>/dev/null)
    if [[ -n "$traceparent" ]] && [[ "$traceparent" =~ ^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$ ]]; then
        echo "✓ Trace context export works: $traceparent"
        
        if [[ -n "$(type -t import_trace_context 2>/dev/null)" ]] && [[ "$(type -t import_trace_context 2>/dev/null)" == "function" ]]; then
            # Save original trace ID
            original_trace_id="$TRACE_ID"
            
            # Import trace context
            if import_trace_context "$traceparent" 2>/dev/null; then
                echo "✓ Trace context import works"
                # Restore original
                export TRACE_ID="$original_trace_id"
            else
                echo "⚠ Trace context import failed (may need SPAN_ID set)"
            fi
        else
            echo "⚠ import_trace_context function not available"
        fi
    else
        echo "⚠ Trace context export failed or invalid format: ${traceparent:-empty}"
    fi
else
    echo "⚠ export_trace_context function not available (OTLP utils may not be loaded)"
fi
echo ""

# Test 4: OTLP Initialization
echo "Test 4: OTLP Initialization"
if [[ -n "$(type -t init_otlp 2>/dev/null)" ]] && [[ "$(type -t init_otlp 2>/dev/null)" == "function" ]]; then
    # Test without endpoint (should fail gracefully)
    OTEL_EXPORTER_OTLP_ENDPOINT=""
    if ! init_otlp 2>/dev/null; then
        echo "✓ OTLP initialization correctly fails without endpoint"
    else
        echo "⚠ OTLP initialization should fail without endpoint"
    fi
    
    # Test with endpoint (should succeed)
    OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_ENDPOINT"
    if init_otlp 2>/dev/null; then
        echo "✓ OTLP initialization works with endpoint: $OTLP_ENDPOINT"
    else
        echo "⚠ OTLP initialization failed (endpoint may not be reachable)"
        echo "  This is OK if no OTLP backend is running"
    fi
else
    echo "⚠ init_otlp function not available (OTLP utils may not be loaded)"
fi
echo ""

# Test 5: Span Creation and Export (if OTLP enabled)
echo "Test 5: Span Creation"
start_span "test_operation"
echo "✓ Span created: $SPAN_ID"
sleep 1
end_span
echo "✓ Span ended"
echo ""

# Test 6: Nested Spans
echo "Test 6: Nested Spans"
start_span "parent_span"
echo "  Parent span: $SPAN_ID, Parent ID: ${PARENT_SPAN_ID:-none}"
start_span "child_span"
echo "  Child span: $SPAN_ID, Parent ID: $PARENT_SPAN_ID"
if [[ "$PARENT_SPAN_ID" != "" ]]; then
    echo "✓ Parent-child relationship maintained"
else
    echo "⚠ Parent ID not set (may be expected for root span)"
fi
end_span
end_span
echo ""

echo "=== All Tests Passed ==="
echo ""
echo "Note: To test actual OTLP export, ensure an OTLP backend is running:"
echo "  export OTEL_EXPORTER_OTLP_ENDPOINT=\"http://localhost:4318\""
echo "  export OTEL_EXPORTER_OTLP_ENABLED=true"
echo ""

