#!/bin/bash

# Enhanced linting script with structured logging, tracing, and metrics
# Runs standard clippy (strict) + baseline clippy rules

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="clippy-lint"

# Source logging utilities
source "$SCRIPT_DIR/logging-utils.sh"

# Source the baseline functions
source "$SCRIPT_DIR/clippy-baseline.sh"

# Initialize script
log_info "🔍 Running all clippy checks..."

FIX_MODE=0
[[ "$1" == "--fix" ]] && FIX_MODE=1

if [[ "$FIX_MODE" -eq 1 ]]; then
    log_info "Mode: Auto-fix enabled"
    record_metric "mode" "fix"
else
    log_info "Mode: Check only"
    record_metric "mode" "check"
fi

# Track metrics
increment_counter "total_runs"
record_metric "fix_mode" "$FIX_MODE"

run_clippy() {
    start_span "clippy_execution"
    
    local clippy_output_file=$(mktemp)
    local clippy_exit_code=0
    
    if [[ "$FIX_MODE" -eq 1 ]]; then
        log_info "🛠  Applying fixes..."
        start_span "cargo_fmt"
        if cargo fmt 2>&1 | tee -a "$LOG_FILE" > "$clippy_output_file.fmt"; then
            log_info "cargo fmt completed successfully"
            record_metric "cargo_fmt_success" "1"
        else
            log_error "cargo fmt failed"
            record_metric "cargo_fmt_success" "0"
            clippy_exit_code=1
        fi
        end_span
        
        start_span "cargo_clippy_fix"
        if cargo clippy --all-targets --jobs 2 \
            --fix --allow-dirty --allow-staged \
            -- -D warnings 2>&1 | tee -a "$LOG_FILE" > "$clippy_output_file.clippy"; then
            log_info "cargo clippy --fix completed successfully"
            record_metric "clippy_fix_success" "1"
        else
            log_warn "cargo clippy --fix completed with warnings/errors"
            record_metric "clippy_fix_success" "0"
            clippy_exit_code=1
        fi
        end_span
    else
        log_info "🔍 Running clippy..."
        start_span "cargo_clippy_check"
        if cargo clippy --all-targets --jobs 2 -- -D warnings 2>&1 | tee -a "$LOG_FILE" > "$clippy_output_file.clippy"; then
            log_info "cargo clippy check completed successfully"
            record_metric "clippy_check_success" "1"
        else
            log_warn "cargo clippy check found issues"
            record_metric "clippy_check_success" "0"
            clippy_exit_code=1
        fi
        end_span
    fi
    
    # Parse clippy output for metrics
    if [[ -f "$clippy_output_file.clippy" ]]; then
        local warning_count=$(grep -c "warning:" "$clippy_output_file.clippy" 2>/dev/null || echo "0")
        local error_count=$(grep -c "error:" "$clippy_output_file.clippy" 2>/dev/null || echo "0")
        
        record_metric "clippy_warnings" "$warning_count"
        record_metric "clippy_errors" "$error_count"
        
        log_info "Clippy results" "warnings=$warning_count" "errors=$error_count"
    fi
    
    rm -f "$clippy_output_file"*
    end_span
    
    return $clippy_exit_code
}

# Run clippy
if ! run_clippy; then
    log_error "Clippy execution failed"
    increment_counter "clippy_failures"
else
    increment_counter "clippy_successes"
fi

# Check baseline rules
log_info ""
start_span "baseline_checks"
if check_all_baseline_rules; then
    log_info "Baseline checks passed"
    record_metric "baseline_checks_success" "1"
    increment_counter "baseline_successes"
else
    log_error "Baseline checks failed"
    record_metric "baseline_checks_success" "0"
    increment_counter "baseline_failures"
    exit 1
fi
end_span

# Check for banned TLS crates
log_info ""
start_span "tls_crate_check"
log_info "🔒 Checking for banned TLS crates..."
if "$SCRIPT_DIR/check-no-native-tls.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log_info "TLS crate check passed"
    record_metric "tls_check_success" "1"
    increment_counter "tls_check_successes"
else
    log_error "TLS crate check failed"
    record_metric "tls_check_success" "0"
    increment_counter "tls_check_failures"
    exit 1
fi
end_span

log_info ""
log_info "✅ Done"

# Summary
log_info "Execution summary" \
    "trace_id=$TRACE_ID" \
    "log_file=$LOG_FILE" \
    "metrics_file=$METRICS_FILE"
