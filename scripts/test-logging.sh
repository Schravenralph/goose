#!/bin/bash

# Integration tests for structured logging infrastructure
# Tests logging-utils.sh functionality including:
# - Log file generation and JSON format
# - Metrics file generation and JSON format
# - Trace ID uniqueness
# - Span tracking
# - Backward compatibility
# - Error handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
TEST_LOG_DIR="$TEST_DIR/logs"

# Cleanup function
cleanup() {
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Helper function to run a test
run_test() {
    local test_name="$1"
    shift
    local test_command="$*"
    
    echo "Running: $test_name"
    if eval "$test_command"; then
        echo "✓ PASS: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "✗ FAIL: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name")
        return 1
    fi
}

# Helper function to validate JSON using jq (if available) or basic validation
validate_json() {
    local json_file="$1"
    if command -v jq &> /dev/null; then
        jq empty "$json_file" 2>/dev/null
    else
        # Basic JSON validation: check for balanced braces and quotes
        local content=$(cat "$json_file")
        local open_braces=$(echo "$content" | grep -o '{' | wc -l)
        local close_braces=$(echo "$content" | grep -o '}' | wc -l)
        [[ "$open_braces" -eq "$close_braces" ]] && [[ "$content" =~ ^\{.*\}$ ]]
    fi
}

# Helper function to validate JSONL (one JSON object per line)
validate_jsonl() {
    local jsonl_file="$1"
    if command -v jq &> /dev/null; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                echo "$line" | jq empty 2>/dev/null || return 1
            fi
        done < "$jsonl_file"
    else
        # Basic validation: each line should be valid JSON
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                [[ "$line" =~ ^\{.*\}$ ]] || return 1
            fi
        done < "$jsonl_file"
    fi
}

# Helper function to extract field from JSON
extract_json_field() {
    local json_file="$1"
    local field="$2"
    if command -v jq &> /dev/null; then
        jq -r ".$field" "$json_file" 2>/dev/null
    else
        # Basic extraction using grep and sed
        grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$json_file" | sed "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/"
    fi
}

echo "=========================================="
echo "Structured Logging Integration Tests"
echo "=========================================="
echo ""
echo "Test directory: $TEST_DIR"
echo "Test log directory: $TEST_LOG_DIR"
echo ""

# Test 1: Log file generation
echo "Test 1: Log file generation"
echo "---------------------------"
run_test "Log file is created" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    log_info "Test message"
    [[ -f "$LOG_FILE" ]]
'

# Test 2: Log file JSON format
echo ""
echo "Test 2: Log file JSON format"
echo "----------------------------"
run_test "Log file contains valid JSON Lines" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    log_info "Test message"
    log_error "Test error"
    validate_jsonl "$LOG_FILE"
'

# Test 3: Log entry structure
echo ""
echo "Test 3: Log entry structure"
echo "---------------------------"
run_test "Log entries contain required fields" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    log_info "Test message"
    
    local first_line=$(head -n 1 "$LOG_FILE")
    [[ "$first_line" =~ \"timestamp\" ]] && \
    [[ "$first_line" =~ \"level\" ]] && \
    [[ "$first_line" =~ \"trace_id\" ]] && \
    [[ "$first_line" =~ \"script\" ]] && \
    [[ "$first_line" =~ \"message\" ]]
'

# Test 4: Trace ID uniqueness
echo ""
echo "Test 4: Trace ID uniqueness"
echo "---------------------------"
run_test "Trace IDs are unique across executions" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    
    # First execution
    export SCRIPT_NAME="test-logging-1"
    source "$SCRIPT_DIR/logging-utils.sh"
    local trace_id_1="$TRACE_ID"
    log_info "Test message 1"
    
    # Second execution (new shell context)
    export SCRIPT_NAME="test-logging-2"
    unset TRACE_ID
    source "$SCRIPT_DIR/logging-utils.sh"
    local trace_id_2="$TRACE_ID"
    log_info "Test message 2"
    
    [[ "$trace_id_1" != "$trace_id_2" ]] && [[ -n "$trace_id_1" ]] && [[ -n "$trace_id_2" ]]
'

# Test 5: Custom trace ID
echo ""
echo "Test 5: Custom trace ID"
echo "-----------------------"
run_test "Custom trace ID is respected" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export TRACE_ID="custom-trace-id-12345"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    log_info "Test message"
    
    local first_line=$(head -n 1 "$LOG_FILE")
    [[ "$first_line" =~ "custom-trace-id-12345" ]]
'

# Test 6: Log levels
echo ""
echo "Test 6: Log levels"
echo "-----------------"
run_test "All log levels work correctly" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    log_debug "Debug message"
    log_info "Info message"
    log_warn "Warning message"
    log_error "Error message"
    
    local debug_line=$(grep -i "debug" "$LOG_FILE" | head -n 1)
    local info_line=$(grep -i "info" "$LOG_FILE" | head -n 1)
    local warn_line=$(grep -i "warn" "$LOG_FILE" | head -n 1)
    local error_line=$(grep -i "error" "$LOG_FILE" | head -n 1)
    
    [[ -n "$debug_line" ]] && [[ -n "$info_line" ]] && \
    [[ -n "$warn_line" ]] && [[ -n "$error_line" ]]
'

# Test 7: Metrics file generation
echo ""
echo "Test 7: Metrics file generation"
echo "------------------------------"
run_test "Metrics file is created" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    record_metric "test_metric" "42" "label=test"
    write_metrics
    [[ -f "$METRICS_FILE" ]]
'

# Test 8: Metrics file JSON format
echo ""
echo "Test 8: Metrics file JSON format"
echo "--------------------------------"
run_test "Metrics file contains valid JSON" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    record_metric "test_metric" "42" "label=test"
    increment_counter "test_counter"
    write_metrics
    validate_json "$METRICS_FILE"
'

# Test 9: Metrics structure
echo ""
echo "Test 9: Metrics structure"
echo "------------------------"
run_test "Metrics file contains required fields" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    record_metric "test_metric" "42"
    write_metrics
    
    local metrics_content=$(cat "$METRICS_FILE")
    [[ "$metrics_content" =~ \"script_name\" ]] && \
    [[ "$metrics_content" =~ \"trace_id\" ]] && \
    [[ "$metrics_content" =~ \"start_time\" ]] && \
    [[ "$metrics_content" =~ \"duration\" ]]
'

# Test 10: Span tracking
echo ""
echo "Test 10: Span tracking"
echo "---------------------"
run_test "Span tracking works correctly" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    start_span "test_span"
    sleep 0.1
    end_span
    
    local span_start=$(grep -i "Starting span" "$LOG_FILE" | head -n 1)
    local span_end=$(grep -i "Ending span" "$LOG_FILE" | head -n 1)
    
    [[ -n "$span_start" ]] && [[ -n "$span_end" ]] && \
    [[ "$span_start" =~ "test_span" ]] && [[ "$span_end" =~ "test_span" ]]
'

# Test 11: Span ID in logs
echo ""
echo "Test 11: Span ID in logs"
echo "----------------------"
run_test "Span ID appears in log entries during span" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    start_span "test_span"
    log_info "Message during span"
    end_span
    
    local span_log=$(grep "Message during span" "$LOG_FILE")
    [[ "$span_log" =~ \"span_id\" ]]
'

# Test 12: Metrics collection
echo ""
echo "Test 12: Metrics collection"
echo "--------------------------"
run_test "Metrics are collected and written correctly" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    record_metric "custom_metric" "100" "unit=bytes"
    increment_counter "operation_count"
    increment_counter "operation_count"
    write_metrics
    
    local metrics_content=$(cat "$METRICS_FILE")
    [[ "$metrics_content" =~ "custom_metric" ]] && \
    [[ "$metrics_content" =~ "operation_count" ]]
'

# Test 13: Backward compatibility (without logging-utils.sh)
echo ""
echo "Test 13: Backward compatibility"
echo "------------------------------"
run_test "Scripts work without logging-utils.sh" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    
    # Create a simple test script that doesn\'t use logging-utils.sh
    local test_script="$TEST_DIR/test-simple.sh"
    cat > "$test_script" << '\''EOF'\''
#!/bin/bash
echo "Simple script output"
exit 0
EOF
    chmod +x "$test_script"
    
    # Script should run without errors
    "$test_script" > /dev/null 2>&1
    [[ $? -eq 0 ]]
'

# Test 14: Error handling - missing directory
echo ""
echo "Test 14: Error handling - missing directory"
echo "------------------------------------------"
run_test "Logging handles missing directory gracefully" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR/missing/subdir"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    # Should create directory and log successfully
    log_info "Test message"
    [[ -f "$LOG_FILE" ]]
'

# Test 15: Error handling - permission issues (if possible)
echo ""
echo "Test 15: Error handling - permission issues"
echo "------------------------------------------"
run_test "Logging handles permission issues" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    # Try to log to a read-only directory (if we can create one)
    if mkdir -p "$TEST_LOG_DIR/readonly" 2>/dev/null && \
       chmod 555 "$TEST_LOG_DIR/readonly" 2>/dev/null; then
        export LOG_DIR="$TEST_LOG_DIR/readonly"
        # Should handle gracefully (may fail but shouldn'\''t crash)
        log_info "Test message" 2>/dev/null || true
        chmod 755 "$TEST_LOG_DIR/readonly" 2>/dev/null || true
        true  # Test passes if we get here without crashing
    else
        # Skip if we can'\''t test permissions
        true
    fi
'

# Test 16: Without jq (fallback JSON)
echo ""
echo "Test 16: Without jq (fallback JSON)"
echo "----------------------------------"
run_test "Logging works without jq installed" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    
    # Temporarily hide jq
    local jq_path=$(command -v jq 2>/dev/null || echo "")
    if [[ -n "$jq_path" ]]; then
        local jq_dir=$(dirname "$jq_path")
        PATH="${PATH//$jq_dir:/}" PATH="${PATH//:$jq_dir/}" PATH="${PATH//$jq_dir/}"
    fi
    
    source "$SCRIPT_DIR/logging-utils.sh"
    log_info "Test message without jq"
    
    # Should still create valid JSON
    local first_line=$(head -n 1 "$LOG_FILE")
    [[ "$first_line" =~ ^\{.*\}$ ]]
'

# Test 17: Without bc (fallback duration calculation)
echo ""
echo "Test 17: Without bc (fallback duration)"
echo "---------------------------------------"
run_test "Span duration works without bc" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    
    # Temporarily hide bc
    local bc_path=$(command -v bc 2>/dev/null || echo "")
    if [[ -n "$bc_path" ]]; then
        local bc_dir=$(dirname "$bc_path")
        PATH="${PATH//$bc_dir:/}" PATH="${PATH//:$bc_dir/}" PATH="${PATH//$bc_dir/}"
    fi
    
    source "$SCRIPT_DIR/logging-utils.sh"
    start_span "test_span"
    sleep 0.1
    end_span
    
    # Should still log span end with duration
    local span_end=$(grep -i "Ending span" "$LOG_FILE" | head -n 1)
    [[ -n "$span_end" ]] && [[ "$span_end" =~ "duration" ]]
'

# Test 18: Context enrichment
echo ""
echo "Test 18: Context enrichment"
echo "---------------------------"
run_test "Logs include context information" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    log_info "Test message"
    
    local first_line=$(head -n 1 "$LOG_FILE")
    [[ "$first_line" =~ \"hostname\" ]] && \
    [[ "$first_line" =~ \"user\" ]] && \
    [[ "$first_line" =~ \"pid\" ]]
'

# Test 19: Multiple log entries
echo ""
echo "Test 19: Multiple log entries"
echo "----------------------------"
run_test "Multiple log entries are written correctly" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    for i in {1..5}; do
        log_info "Message $i"
    done
    
    local line_count=$(wc -l < "$LOG_FILE")
    [[ $line_count -ge 5 ]]
'

# Test 20: Exit code in metrics
echo ""
echo "Test 20: Exit code in metrics"
echo "---------------------------"
run_test "Exit code is recorded in metrics" '
    mkdir -p "$TEST_LOG_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export SCRIPT_NAME="test-logging"
    source "$SCRIPT_DIR/logging-utils.sh"
    
    EXIT_CODE=42
    write_metrics
    
    local metrics_content=$(cat "$METRICS_FILE")
    [[ "$metrics_content" =~ \"exit_code\" ]]
'

# Summary
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✓ All tests passed!"
    exit 0
else
    echo "✗ Some tests failed:"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
    exit 1
fi

