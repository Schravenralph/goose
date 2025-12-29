#!/bin/bash
# Test script for lead/worker provider functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="test_lead_worker"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

if command -v log_info &> /dev/null; then
  log_info "Testing lead/worker provider functionality"
  start_span "lead_worker_tests"
  increment_counter "lead_worker_test_runs"
fi

# Set up test environment variables
export GOOSE_PROVIDER="openai"
export GOOSE_MODEL="gpt-4o-mini"
export OPENAI_API_KEY="test-key"

# Test 1: Default behavior (no lead/worker)
echo "Test 1: Default behavior (no lead/worker)"
unset GOOSE_LEAD_MODEL
unset GOOSE_WORKER_MODEL
unset GOOSE_LEAD_TURNS

# Test 2: Lead/worker with same provider
echo -e "\nTest 2: Lead/worker with same provider"
export GOOSE_LEAD_MODEL="gpt-4o"
export GOOSE_WORKER_MODEL="gpt-4o-mini"
export GOOSE_LEAD_TURNS="3"

# Test 3: Lead/worker with default worker (uses main model)
echo -e "\nTest 3: Lead/worker with default worker"
export GOOSE_LEAD_MODEL="gpt-4o"
unset GOOSE_WORKER_MODEL
export GOOSE_LEAD_TURNS="5"

if command -v log_info &> /dev/null; then
  log_info "Configuration examples documented"
  record_metric "test_scenarios" "3"
  end_span
else
  echo -e "\nConfiguration examples:"
  echo "- Default: Uses GOOSE_MODEL for all turns"
  echo "- Lead/Worker: Set GOOSE_LEAD_MODEL to use a different model for initial turns"
  echo "- GOOSE_LEAD_TURNS: Number of turns to use lead model (default: 5)"
  echo "- GOOSE_WORKER_MODEL: Model to use after lead turns (default: GOOSE_MODEL)"
fi