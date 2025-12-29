#!/usr/bin/env bash
# Script to parse goose-bench results and check for failures

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="parse-benchmark-results"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

if [ "$#" -ne 1 ]; then
  if command -v log_error &> /dev/null; then
    log_error "Usage: $0 <benchmark-result-json-file>"
  else
    echo "Usage: $0 <benchmark-result-json-file>"
  fi
  exit 1
fi

RESULT_FILE="$1"

if [ ! -f "$RESULT_FILE" ]; then
  if command -v log_error &> /dev/null; then
    log_error "Result file not found: $RESULT_FILE"
  else
    echo "Error: Result file not found: $RESULT_FILE"
  fi
  exit 1
fi

if command -v log_info &> /dev/null; then
  log_info "Parsing benchmark results" "file=$RESULT_FILE"
  start_span "parse_benchmark_results"
  record_metric "result_file" "$RESULT_FILE"
fi

# Extract basic information
PROVIDER=$(jq -r '.provider' "$RESULT_FILE")
START_TIME=$(jq -r '.start_time' "$RESULT_FILE")
SUITE_COUNT=$(jq '.suites | length' "$RESULT_FILE")

if command -v log_info &> /dev/null; then
  log_info "Benchmark Results Analysis" "provider=$PROVIDER" "start_time=$START_TIME" "suite_count=$SUITE_COUNT"
  record_metric "provider" "$PROVIDER"
  record_metric "suite_count" "$SUITE_COUNT"
else
  echo "Benchmark Results Analysis"
  echo "-------------------------"
  echo "Provider: $PROVIDER"
  echo "Start Time: $START_TIME"
  echo "Number of Suites: $SUITE_COUNT"
  echo ""
fi

# Initialize counters
TOTAL_EVALS=0
TOTAL_METRICS=0
FAILED_METRICS=0
PASSED_METRICS=0

# Process each suite
for i in $(seq 0 $((SUITE_COUNT-1))); do
  SUITE_NAME=$(jq -r ".suites[$i].name" "$RESULT_FILE")
  EVAL_COUNT=$(jq ".suites[$i].evaluations | length" "$RESULT_FILE")
  TOTAL_EVALS=$((TOTAL_EVALS + EVAL_COUNT))
  
  if command -v log_info &> /dev/null; then
    log_info "Processing suite" "suite=$SUITE_NAME" "eval_count=$EVAL_COUNT"
  else
    echo "Suite: $SUITE_NAME ($EVAL_COUNT evaluations)"
  fi
  
  # Process each evaluation in this suite
  for j in $(seq 0 $((EVAL_COUNT-1))); do
    EVAL_NAME=$(jq -r ".suites[$i].evaluations[$j].name" "$RESULT_FILE")
    METRIC_COUNT=$(jq ".suites[$i].evaluations[$j].metrics | length" "$RESULT_FILE")
    TOTAL_METRICS=$((TOTAL_METRICS + METRIC_COUNT))
    
    # Check for failures in this evaluation
    # This assumes metrics with names containing "success", "pass", or "correct" 
    # and boolean values of false indicate failures
    FAILURES=$(jq -r ".suites[$i].evaluations[$j].metrics[] | 
      select(
        (.[0] | test(\"success|pass|correct\"; \"i\")) and 
        (.[1] == false or .[1] == \"false\" or .[1] == 0 or .[1] == \"0\")
      ) | .[0]" "$RESULT_FILE" | wc -l | tr -d ' ')
    
    if [ "$FAILURES" -gt 0 ]; then
      FAILED_METRICS=$((FAILED_METRICS + FAILURES))
      if command -v log_error &> /dev/null; then
        log_error "Evaluation failed" "eval=$EVAL_NAME" "failures=$FAILURES" "suite=$SUITE_NAME"
        increment_counter "failed_evaluations"
      else
        echo "  ❌ $EVAL_NAME: $FAILURES failures detected"
      fi
      
      # Print the specific failing metrics
      FAILING_METRICS=$(jq -r ".suites[$i].evaluations[$j].metrics[] | 
        select(
          (.[0] | test(\"success|pass|correct\"; \"i\")) and 
          (.[1] == false or .[1] == \"false\" or .[1] == 0 or .[1] == \"0\")
        ) | \"    - \" + .[0]" "$RESULT_FILE")
      if [ -z "$(command -v log_error 2>/dev/null)" ]; then
        echo "$FAILING_METRICS"
      fi
    else
      PASSED_METRICS=$((PASSED_METRICS + METRIC_COUNT))
      if command -v log_info &> /dev/null; then
        log_info "Evaluation passed" "eval=$EVAL_NAME" "suite=$SUITE_NAME"
        increment_counter "passed_evaluations"
      else
        echo "  ✅ $EVAL_NAME: All metrics passed"
      fi
    fi
  done
  if [ -z "$(command -v log_info 2>/dev/null)" ]; then
    echo ""
  fi
done

# Print summary
if command -v log_info &> /dev/null; then
  log_info "Summary" "total_evals=$TOTAL_EVALS" "total_metrics=$TOTAL_METRICS" "passed_metrics=$PASSED_METRICS" "failed_metrics=$FAILED_METRICS"
  record_metric "total_evaluations" "$TOTAL_EVALS"
  record_metric "total_metrics" "$TOTAL_METRICS"
  record_metric "passed_metrics" "$PASSED_METRICS"
  record_metric "failed_metrics" "$FAILED_METRICS"
  end_span
else
  echo "Summary:"
  echo "-------"
  echo "Total Evaluations: $TOTAL_EVALS"
  echo "Total Metrics: $TOTAL_METRICS"
  echo "Passed Metrics: $PASSED_METRICS"
  echo "Failed Metrics: $FAILED_METRICS"
fi

# Set exit code based on failures
if [ "$FAILED_METRICS" -gt 0 ]; then
  if command -v log_error &> /dev/null; then
    log_error "Benchmark has failures" "failed_metrics=$FAILED_METRICS"
  else
    echo "❌ Benchmark has $FAILED_METRICS failures"
  fi
  exit 1
else
  if command -v log_info &> /dev/null; then
    log_info "All metrics passed successfully"
  else
    echo "✅ All metrics passed successfully"
  fi
  exit 0
fi