#!/bin/bash

# Test script for alerting system
# This script tests various alert scenarios

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logging-utils.sh"
source "$SCRIPT_DIR/alerting-utils.sh"

echo "Testing Goose Alerting System"
echo "=============================="
echo ""

# Test 1: Script failure alert
echo "Test 1: Script failure alert"
echo "This test will trigger a script failure alert..."
log_info "Simulating script failure"
EXIT_CODE=1
check_script_failure "$EXIT_CODE"
echo "✓ Script failure alert test complete"
echo ""

# Test 2: High error count alert
echo "Test 2: High error count alert"
echo "This test will trigger a high error count alert..."
log_error "Test error 1"
log_error "Test error 2"
check_error_count "$LOG_FILE" 2
echo "✓ High error count alert test complete"
echo ""

# Test 3: Performance degradation alert
echo "Test 3: Performance degradation alert"
echo "This test will trigger a performance degradation alert..."
# Simulate long duration (set threshold low for testing)
DURATION_THRESHOLD=1  # 1 second for testing
check_performance_degradation 2
echo "✓ Performance degradation alert test complete"
echo ""

# Test 4: Custom alert
echo "Test 4: Custom alert"
echo "This test will send a custom alert..."
send_alert "$SEVERITY_MEDIUM" "test_alert" \
    "This is a test alert from the alerting system" \
    '{"test": true, "scenario": "custom_alert"}'
echo "✓ Custom alert test complete"
echo ""

# Test 5: Alert deduplication
echo "Test 5: Alert deduplication"
echo "This test verifies alert deduplication..."
send_alert "$SEVERITY_LOW" "dedup_test" "First alert" '{"test": "dedup"}'
send_alert "$SEVERITY_LOW" "dedup_test" "Second alert (should be deduplicated)" '{"test": "dedup"}'
echo "✓ Alert deduplication test complete"
echo ""

echo "All tests complete!"
echo ""
echo "Check alert log: $ALERT_LOG_FILE"
echo "Check deduplication file: $ALERT_DEDUP_FILE"

