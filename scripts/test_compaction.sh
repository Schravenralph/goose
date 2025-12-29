#!/bin/bash

# Compaction smoke test script
# Tests both manual (trigger prompt) and auto compaction (threshold-based)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="test_compaction"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
  if command -v log_debug &> /dev/null; then
    log_debug "Loaded environment variables from .env"
  fi
fi

if command -v log_info &> /dev/null; then
  log_info "Starting compaction tests"
  start_span "compaction_tests"
  increment_counter "compaction_test_runs"
fi

if [ -z "$SKIP_BUILD" ]; then
  if command -v log_info &> /dev/null; then
    log_info "Building goose..."
    start_span "build"
  else
    echo "Building goose..."
  fi
  cargo build --release --bin goose
  if command -v end_span &> /dev/null; then
    end_span
    log_info "Build completed"
    record_metric "build_success" "1"
  else
    echo ""
  fi
else
  if command -v log_info &> /dev/null; then
    log_info "Skipping build (SKIP_BUILD is set)..."
    record_metric "build_skipped" "1"
  else
    echo "Skipping build (SKIP_BUILD is set)..."
  fi
  echo ""
fi

GOOSE_BIN="$SCRIPT_DIR/target/release/goose"

# Validation function to check compaction structure in session JSON
validate_compaction() {
  local session_id=$1
  local test_name=$2

  echo "Validating compaction structure for session: $session_id"

  # Export the session to JSON
  local session_json=$($GOOSE_BIN session export --format json --session-id "$session_id" 2>&1)

  if [ $? -ne 0 ]; then
    echo "✗ FAILED: Could not export session JSON"
    echo "   Error: $session_json"
    return 1
  fi

  if ! command -v jq &> /dev/null; then
    echo "⚠ WARNING: jq not available, cannot validate compaction structure"
    return 0
  fi

  # Check basic structure
  echo "$session_json" | jq -e '.conversation' > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "✗ FAILED: Session JSON missing 'conversation' field"
    return 1
  fi

  local message_count=$(echo "$session_json" | jq '.conversation | length' 2>/dev/null)
  echo "   Session has $message_count messages"

  # Look for a summary message (assistant role with userVisible=false, agentVisible=true)
  local has_summary=$(echo "$session_json" | jq '[.conversation[] | select(.role == "assistant" and .metadata.userVisible == false and .metadata.agentVisible == true)] | length > 0' 2>/dev/null)

  if [ "$has_summary" != "true" ]; then
    echo "✗ FAILED: No summary message found (expected assistant message with userVisible=false, agentVisible=true)"
    return 1
  fi
  echo "✓ Found summary message with correct visibility flags"

  # Check for original messages with userVisible=true, agentVisible=false
  local has_hidden_originals=$(echo "$session_json" | jq '[.conversation[] | select(.metadata.userVisible == true and .metadata.agentVisible == false)] | length > 0' 2>/dev/null)

  if [ "$has_hidden_originals" != "true" ]; then
    echo "⚠ WARNING: No original messages found with userVisible=true, agentVisible=false"
    echo "   This might be OK if all messages were compacted"
  else
    echo "✓ Found original messages hidden from agent (userVisible=true, agentVisible=false)"
  fi

  # For auto-compaction, check for the preserved user message (userVisible=true, agentVisible=true)
  local has_preserved_user=$(echo "$session_json" | jq '[.conversation[] | select(.role == "user" and .metadata.userVisible == true and .metadata.agentVisible == true)] | length > 0' 2>/dev/null)

  if [ "$has_preserved_user" == "true" ]; then
    echo "✓ Found preserved user message (userVisible=true, agentVisible=true)"
  fi

  echo "✓ SUCCESS: Compaction structure is valid for $test_name"
  return 0
}

if command -v log_info &> /dev/null; then
  log_info "Starting compaction smoke tests"
else
  echo "=================================================="
  echo "COMPACTION SMOKE TESTS"
  echo "=================================================="
  echo ""
fi

RESULTS=()

# ==================================================
# TEST 1: Manual Compaction
# ==================================================
if command -v log_info &> /dev/null; then
  log_info "TEST 1: Manual Compaction via trigger prompt"
  start_span "test_manual_compaction"
else
  echo "---------------------------------------------------"
  echo "TEST 1: Manual Compaction via trigger prompt"
  echo "---------------------------------------------------"
fi

TESTDIR=$(mktemp -d)
echo "hello world" > "$TESTDIR/hello.txt"
if command -v log_info &> /dev/null; then
  log_info "Test directory created" "dir=$TESTDIR"
else
  echo "Test directory: $TESTDIR"
  echo ""
fi

OUTPUT=$(mktemp)

if command -v log_info &> /dev/null; then
  log_info "Step 1: Creating session with initial messages..."
else
  echo "Step 1: Creating session with initial messages..."
fi
(cd "$TESTDIR" && "$GOOSE_BIN" run --text "list files and read hello.txt" 2>&1) | tee "$OUTPUT"

if ! command -v jq &> /dev/null; then
  echo "✗ FAILED: jq is required for this test"
  RESULTS+=("✗ Manual Compaction (jq required)")
  rm -f "$OUTPUT"
  rm -rf "$TESTDIR"
else
  SESSION_ID=$("$GOOSE_BIN" session list --format json 2>/dev/null | jq -r '.[0].id' 2>/dev/null)

  if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
    if command -v log_error &> /dev/null; then
      log_error "Could not create session"
      increment_counter "session_creation_failures"
    else
      echo "✗ FAILED: Could not create session"
    fi
    RESULTS+=("✗ Manual Compaction (no session)")
  else
    if command -v log_info &> /dev/null; then
      log_info "Session created" "session_id=$SESSION_ID"
      log_info "Step 2: Sending manual compaction trigger..."
    else
      echo ""
      echo "Session created: $SESSION_ID"
      echo "Step 2: Sending manual compaction trigger..."
    fi

    # Send the manual compact trigger prompt
    (cd "$TESTDIR" && "$GOOSE_BIN" run --resume --session-id "$SESSION_ID" --text "Please compact this conversation" 2>&1) | tee -a "$OUTPUT"

    if command -v log_info &> /dev/null; then
      log_info "Checking for compaction evidence..."
    else
      echo ""
      echo "Checking for compaction evidence..."
    fi

    if grep -qi "compacting\|compacted\|compaction" "$OUTPUT"; then
      if command -v log_info &> /dev/null; then
        log_info "✓ SUCCESS: Manual compaction was triggered"
        increment_counter "manual_compactions_triggered"
      else
        echo "✓ SUCCESS: Manual compaction was triggered"
      fi

      if validate_compaction "$SESSION_ID" "manual compaction"; then
        if command -v increment_counter &> /dev/null; then
          increment_counter "manual_compaction_validations_passed"
        fi
        RESULTS+=("✓ Manual Compaction")
      else
        if command -v increment_counter &> /dev/null; then
          increment_counter "manual_compaction_validations_failed"
        fi
        RESULTS+=("✗ Manual Compaction (structure validation failed)")
      fi
    else
      if command -v log_error &> /dev/null; then
        log_error "✗ FAILED: Manual compaction was not triggered"
        increment_counter "manual_compaction_failures"
      else
        echo "✗ FAILED: Manual compaction was not triggered"
      fi
      RESULTS+=("✗ Manual Compaction")
    fi
  fi

  rm -f "$OUTPUT"
  rm -rf "$TESTDIR"
fi

if command -v end_span &> /dev/null; then
  end_span
fi

if [ -z "$(command -v log_info 2>/dev/null)" ]; then
  echo ""
  echo ""
fi

# ==================================================
# TEST 2: Auto Compaction
# ==================================================
if command -v log_info &> /dev/null; then
  log_info "TEST 2: Auto Compaction via threshold (0.005)"
  start_span "test_auto_compaction"
else
  echo "---------------------------------------------------"
  echo "TEST 2: Auto Compaction via threshold (0.005)"
  echo "---------------------------------------------------"
fi

TESTDIR=$(mktemp -d)
echo "test content" > "$TESTDIR/test.txt"
echo "Test directory: $TESTDIR"
echo ""

# Set auto-compact threshold very low (.5%) to trigger it quickly
export GOOSE_AUTO_COMPACT_THRESHOLD=0.005

if command -v log_info &> /dev/null; then
  log_info "Set auto-compact threshold" "threshold=0.005"
  record_metric "auto_compact_threshold" "0.005"
fi

OUTPUT=$(mktemp)

if command -v log_info &> /dev/null; then
  log_info "Step 1: Creating session with first message..."
else
  echo "Step 1: Creating session with first message..."
fi
(cd "$TESTDIR" && "$GOOSE_BIN" run --text "hello" 2>&1) | tee "$OUTPUT"

if ! command -v jq &> /dev/null; then
  echo "✗ FAILED: jq is required for this test"
  RESULTS+=("✗ Auto Compaction (jq required)")
else
  SESSION_ID=$("$GOOSE_BIN" session list --format json 2>/dev/null | jq -r '.[0].id' 2>/dev/null)

  if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
    if command -v log_error &> /dev/null; then
      log_error "Could not create session"
      increment_counter "session_creation_failures"
    else
      echo "✗ FAILED: Could not create session"
    fi
    RESULTS+=("✗ Auto Compaction (no session)")
  else
    if command -v log_info &> /dev/null; then
      log_info "Session created" "session_id=$SESSION_ID"
      log_info "Step 2: Sending second message (should trigger auto-compact)..."
    else
      echo ""
      echo "Session created: $SESSION_ID"
      echo "Step 2: Sending second message (should trigger auto-compact)..."
    fi

    # Send second message - auto-compaction should trigger before processing this
    (cd "$TESTDIR" && "$GOOSE_BIN" run --resume --session-id "$SESSION_ID" --text "hi again" 2>&1) | tee -a "$OUTPUT"

    if command -v log_info &> /dev/null; then
      log_info "Checking for auto-compaction evidence..."
    else
      echo ""
      echo "Checking for auto-compaction evidence..."
    fi

    if grep -qi "auto.*compact\|exceeded.*auto.*compact.*threshold" "$OUTPUT"; then
      if command -v log_info &> /dev/null; then
        log_info "✓ SUCCESS: Auto compaction was triggered"
        increment_counter "auto_compactions_triggered"
      else
        echo "✓ SUCCESS: Auto compaction was triggered"
      fi

      if validate_compaction "$SESSION_ID" "auto compaction"; then
        if command -v increment_counter &> /dev/null; then
          increment_counter "auto_compaction_validations_passed"
        fi
        RESULTS+=("✓ Auto Compaction")
      else
        if command -v increment_counter &> /dev/null; then
          increment_counter "auto_compaction_validations_failed"
        fi
        RESULTS+=("✗ Auto Compaction (structure validation failed)")
      fi
    else
      if command -v log_error &> /dev/null; then
        log_error "✗ FAILED: Auto compaction was not triggered"
        log_error "Expected to see auto-compact messages with threshold of 0.005"
        increment_counter "auto_compaction_failures"
      else
        echo "✗ FAILED: Auto compaction was not triggered"
        echo "   Expected to see auto-compact messages with threshold of 0.005"
      fi
      RESULTS+=("✗ Auto Compaction")
    fi
  fi
fi

# Unset the env variable
unset GOOSE_AUTO_COMPACT_THRESHOLD

if command -v end_span &> /dev/null; then
  end_span
fi

rm -f "$OUTPUT"
rm -rf "$TESTDIR"

if [ -z "$(command -v log_info 2>/dev/null)" ]; then
  echo ""
  echo ""
fi

# ==================================================
# TEST 3: Out-of-Context Error Compaction
# ==================================================
if command -v log_info &> /dev/null; then
  log_info "TEST 3: Compaction via out-of-context error (proxy)"
  start_span "test_out_of_context_compaction"
else
  echo "---------------------------------------------------"
  echo "TEST 3: Compaction via out-of-context error (proxy)"
  echo "---------------------------------------------------"
fi

TESTDIR=$(mktemp -d)
echo "test content" > "$TESTDIR/test.txt"
if command -v log_info &> /dev/null; then
  log_info "Test directory created" "dir=$TESTDIR"
else
  echo "Test directory: $TESTDIR"
  echo ""
fi

# Use a random port to avoid conflicts
PROXY_PORT=$((9000 + RANDOM % 1000))
PROXY_DIR="$SCRIPT_DIR/scripts/provider-error-proxy"

OUTPUT=$(mktemp)
PROXY_LOG=$(mktemp)
PROXY_SETUP_LOG=$(mktemp)

# Pre-install proxy dependencies (so first run doesn't take forever)
if command -v log_info &> /dev/null; then
  log_info "Installing proxy dependencies..."
  start_span "install_proxy_dependencies"
else
  echo "Installing proxy dependencies..."
fi
export UV_INDEX_URL="https://pypi.org/simple"
if ! (cd "$PROXY_DIR" && uv sync 2>&1 | tee "$PROXY_SETUP_LOG"); then
  if command -v log_error &> /dev/null; then
    log_error "Could not install proxy dependencies"
    end_span
    increment_counter "proxy_dependency_install_failures"
  else
    echo "✗ FAILED: Could not install proxy dependencies"
    echo "Setup log:"
    cat "$PROXY_SETUP_LOG"
  fi
  RESULTS+=("✗ Out-of-Context Error (dependency install failed)")
else
  if command -v log_info &> /dev/null; then
    log_info "✓ Dependencies installed"
    end_span
    increment_counter "proxy_dependency_installs_successful"
  else
    echo "✓ Dependencies installed"
  fi

  # Start the error proxy in context-length error mode (3 errors)
  if command -v log_info &> /dev/null; then
    log_info "Starting error proxy" "port=$PROXY_PORT" "mode=context-length"
    start_span "start_error_proxy"
  else
    echo "Starting error proxy on port $PROXY_PORT with context-length error mode..."
  fi
  (cd "$PROXY_DIR" && UV_INDEX_URL="https://pypi.org/simple" uv run proxy.py --port "$PROXY_PORT" --mode "c 3" --no-stdin > "$PROXY_LOG" 2>&1) &
  PROXY_PID=$!

  # Wait for proxy to be ready (check if port is listening)
  echo "Waiting for proxy to be ready..."
  PROXY_READY=false
  for i in {1..60}; do
    if kill -0 $PROXY_PID 2>/dev/null; then
      # Check if port is listening using /dev/tcp
      if timeout 1 bash -c "echo -n > /dev/tcp/localhost/$PROXY_PORT" 2>/dev/null; then
        PROXY_READY=true
        if command -v log_info &> /dev/null; then
          log_info "✓ Proxy is ready" "port=$PROXY_PORT"
          end_span
          record_metric "proxy_port" "$PROXY_PORT"
        else
          echo "✓ Proxy is ready on port $PROXY_PORT"
        fi
        break
      fi
    else
      if command -v log_error &> /dev/null; then
        log_error "Error proxy process died"
      else
        echo "✗ FAILED: Error proxy process died"
      fi
      break
    fi
    sleep 0.5
  done

  # Check if proxy is running and ready
  if [ "$PROXY_READY" != "true" ]; then
    if command -v log_error &> /dev/null; then
      log_error "Error proxy failed to become ready"
      log_error "Proxy log:" "$(cat "$PROXY_LOG")"
      increment_counter "proxy_start_failures"
    else
      echo "✗ FAILED: Error proxy failed to become ready"
      echo "Proxy log:"
      cat "$PROXY_LOG"
    fi
    kill $PROXY_PID 2>/dev/null || true
    RESULTS+=("✗ Out-of-Context Test Error (proxy failed)")
  else
    # Configure provider to use proxy and skip backoff
    export ANTHROPIC_HOST="http://localhost:$PROXY_PORT"
    export GOOSE_PROVIDER_SKIP_BACKOFF=true
    export GOOSE_PROVIDER=anthropic
    export GOOSE_MODEL=claude-haiku-4-5

    if command -v log_info &> /dev/null; then
      log_info "Step 1: Creating session (should trigger context-length error and compaction)..."
    else
      echo "Step 1: Creating session (should trigger context-length error and compaction)..."
    fi
    (cd "$TESTDIR" && "$GOOSE_BIN" run --text "hello world" 2>&1) | tee "$OUTPUT"

    SESSION_ID=$("$GOOSE_BIN" session list --format json 2>/dev/null | jq -r '.[0].id' 2>/dev/null)

    if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
      if command -v log_error &> /dev/null; then
        log_error "Could not create session"
        increment_counter "session_creation_failures"
      else
        echo "✗ FAILED: Could not create session"
      fi
      RESULTS+=("✗ Out-of-Context Test Error (no session)")
    else
      if command -v log_info &> /dev/null; then
        log_info "Session created" "session_id=$SESSION_ID"
        log_info "Checking for compaction evidence..."
      else
        echo ""
        echo "Session created: $SESSION_ID"
        echo "Checking for compaction evidence..."
      fi

      # Check for compaction in the output
      if grep -qi "context.*length\|compacting\|compacted\|compaction" "$OUTPUT"; then
        if command -v log_info &> /dev/null; then
          log_info "✓ SUCCESS: Out-of-context Test error triggered compaction"
          increment_counter "out_of_context_compactions_triggered"
        else
          echo "✓ SUCCESS: Out-of-context Test error triggered compaction"
        fi

        if validate_compaction "$SESSION_ID" "out-of-context error compaction"; then
          if command -v increment_counter &> /dev/null; then
            increment_counter "out_of_context_compaction_validations_passed"
          fi
          RESULTS+=("✓ Out-of-Context Test Error")
        else
          if command -v increment_counter &> /dev/null; then
            increment_counter "out_of_context_compaction_validations_failed"
          fi
          RESULTS+=("✗ Out-of-Context Test Error (structure validation failed)")
        fi
      else
        if command -v log_error &> /dev/null; then
          log_error "✗ FAILED: No evidence of compaction after context-length error"
          log_error "Output:" "$(cat "$OUTPUT")"
          increment_counter "out_of_context_compaction_failures"
        else
          echo "✗ FAILED: No evidence of compaction after context-length error"
          echo "   Output:"
          cat "$OUTPUT"
        fi
        RESULTS+=("✗ Out-of-Context Test Error")
      fi
    fi

    # Clean up
    echo ""
    echo "Stopping error proxy..."
    # Kill the entire process group to ensure UV and Python processes are terminated
    kill -- -$PROXY_PID 2>/dev/null || true
    # Also explicitly kill any remaining UV processes on this port
    pkill -f "uv run.*--port $PROXY_PORT" 2>/dev/null || true
    wait $PROXY_PID 2>/dev/null || true
    unset ANTHROPIC_HOST
    unset GOOSE_PROVIDER_SKIP_BACKOFF
    unset GOOSE_PROVIDER
    unset GOOSE_MODEL
    unset UV_INDEX_URL
  fi
fi

rm -f "$OUTPUT" "$PROXY_LOG" "$PROXY_SETUP_LOG"
rm -rf "$TESTDIR"

echo ""
echo ""

# ==================================================
# Summary
# ==================================================
if command -v end_span &> /dev/null; then
    end_span
fi

if command -v log_info &> /dev/null; then
  log_info "Test Summary"
else
  echo "=================================================="
  echo "TEST SUMMARY"
  echo "=================================================="
fi

for result in "${RESULTS[@]}"; do
  echo "$result"
done

# Count results
FAILURE_COUNT=$(echo "${RESULTS[@]}" | grep -o "✗" | wc -l | tr -d ' ')
PASS_COUNT=$(echo "${RESULTS[@]}" | grep -o "✓" | wc -l | tr -d ' ')

if command -v record_metric &> /dev/null; then
    record_metric "total_compaction_tests" "${#RESULTS[@]}"
    record_metric "passed_compaction_tests" "$PASS_COUNT"
    record_metric "failed_compaction_tests" "$FAILURE_COUNT"
fi

if [ "$FAILURE_COUNT" -gt 0 ]; then
  if command -v log_error &> /dev/null; then
    log_error "$FAILURE_COUNT test(s) failed!" "total=${#RESULTS[@]}"
  else
    echo ""
    echo "❌ $FAILURE_COUNT test(s) failed!"
  fi
  exit 1
else
  if command -v log_info &> /dev/null; then
    log_info "All tests passed!" "total=${#RESULTS[@]}"
  else
    echo ""
    echo "✅ All tests passed!"
  fi
fi
