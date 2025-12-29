#!/bin/bash
# Test providers with optional code_execution mode
# Usage:
#   ./test_providers.sh              # Normal mode (direct tool calls)
#   ./test_providers.sh --code-exec  # Code execution mode (JS batching)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="test_providers"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

CODE_EXEC_MODE=false
for arg in "$@"; do
  case $arg in
    --code-exec)
      CODE_EXEC_MODE=true
      ;;
  esac
done

# Initialize metrics
if command -v record_metric &> /dev/null; then
    record_metric "code_exec_mode" "$CODE_EXEC_MODE"
fi

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
  if command -v log_debug &> /dev/null; then
    log_debug "Loaded environment variables from .env"
  fi
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

PROVIDERS=(
  "openrouter:google/gemini-2.5-pro:google/gemini-2.5-flash:anthropic/claude-sonnet-4.5:qwen/qwen3-coder:z-ai/glm-4.6"
  "xai:grok-3"
  "openai:gpt-4o:gpt-4o-mini:gpt-3.5-turbo:gpt-5"
  "anthropic:claude-sonnet-4-5-20250929:claude-opus-4-1-20250805"
  "google:gemini-2.5-pro:gemini-2.5-flash:gemini-3-pro-preview:gemini-3-flash-preview"
  "tetrate:claude-sonnet-4-20250514"
)

# In CI, only run Databricks tests if DATABRICKS_HOST and DATABRICKS_TOKEN are set
# Locally, always run Databricks tests
if [ -n "$CI" ]; then
  if [ -n "$DATABRICKS_HOST" ] && [ -n "$DATABRICKS_TOKEN" ]; then
    if command -v log_info &> /dev/null; then
      log_info "✓ Including Databricks tests"
    else
      echo "✓ Including Databricks tests"
    fi
    PROVIDERS+=("databricks:databricks-claude-sonnet-4:gemini-2-5-flash:gpt-4o")
  else
    if command -v log_warn &> /dev/null; then
      log_warn "Skipping Databricks tests (DATABRICKS_HOST and DATABRICKS_TOKEN required in CI)"
    else
      echo "⚠️  Skipping Databricks tests (DATABRICKS_HOST and DATABRICKS_TOKEN required in CI)"
    fi
  fi
else
  if command -v log_info &> /dev/null; then
    log_info "✓ Including Databricks tests"
  else
    echo "✓ Including Databricks tests"
  fi
  PROVIDERS+=("databricks:databricks-claude-sonnet-4:gemini-2-5-flash:gpt-4o")
fi

# Configure mode-specific settings
if [ "$CODE_EXEC_MODE" = true ]; then
  if command -v log_info &> /dev/null; then
    log_info "Mode: code_execution (JS batching)"
  else
    echo "Mode: code_execution (JS batching)"
  fi
  BUILTINS="developer,code_execution"
  # Match code_execution tool usage:
  # - "execute_code | code_execution" or "read_module | code_execution" (fallback format)
  # - "tool call | execute_code" or "tool calls | execute_code" (new format with tool_graph)
  SUCCESS_PATTERN="(execute_code \| code_execution)|(read_module \| code_execution)|(tool calls? \| execute_code)"
  SUCCESS_MSG="code_execution tool called"
  FAILURE_MSG="no code_execution tools called"
else
  if command -v log_info &> /dev/null; then
    log_info "Mode: normal (direct tool calls)"
  else
    echo "Mode: normal (direct tool calls)"
  fi
  BUILTINS="developer,autovisualiser,computercontroller,tutorial,todo,extensionmanager"
  SUCCESS_PATTERN="shell \| developer"
  SUCCESS_MSG="developer tool called"
  FAILURE_MSG="no developer tools called"
fi

# Initialize logging and metrics
if command -v log_info &> /dev/null; then
  log_info "🧪 Starting provider tests"
  if [ "$CODE_EXEC_MODE" = true ]; then
    log_info "Mode: code_execution (JS batching)"
  else
    log_info "Mode: normal (direct tool calls)"
  fi
  record_metric "mode" "$([ "$CODE_EXEC_MODE" = true ] && echo "code_execution" || echo "normal")"
  increment_counter "test_runs"
fi

if ! command -v log_info &> /dev/null; then
  echo ""
fi

RESULTS=()
PASSED_COUNT=0
FAILED_COUNT=0

for provider_config in "${PROVIDERS[@]}"; do
  IFS=':' read -ra PARTS <<< "$provider_config"
  PROVIDER="${PARTS[0]}"
  for i in $(seq 1 $((${#PARTS[@]} - 1))); do
    MODEL="${PARTS[$i]}"
    export GOOSE_PROVIDER="$PROVIDER"
    export GOOSE_MODEL="$MODEL"
    
    if command -v start_span &> /dev/null; then
      start_span "test_provider_model"
    fi
    
    TESTDIR=$(mktemp -d)
    echo "hello" > "$TESTDIR/hello.txt"
    
    if command -v log_info &> /dev/null; then
      log_info "Testing provider" "provider=$PROVIDER" "model=$MODEL"
    else
      echo "Provider: ${PROVIDER}"
      echo "Model: ${MODEL}"
    fi
    echo ""
    
    TMPFILE=$(mktemp)
    if (cd "$TESTDIR" && "$SCRIPT_DIR/target/release/goose" run --text "please list files in the current directory" --with-builtin "$BUILTINS" 2>&1) | tee "$TMPFILE"; then
      TEST_EXIT_CODE=0
    else
      TEST_EXIT_CODE=$?
    fi
    echo ""
    
    if grep -qE "$SUCCESS_PATTERN" "$TMPFILE"; then
      if command -v log_info &> /dev/null; then
        log_info "✓ SUCCESS: Test passed - $SUCCESS_MSG" "provider=$PROVIDER" "model=$MODEL"
        increment_counter "tests_passed"
        record_metric "test_result" "passed" "provider=$PROVIDER" "model=$MODEL"
      else
        echo "✓ SUCCESS: Test passed - $SUCCESS_MSG"
      fi
      RESULTS+=("✓ ${PROVIDER}: ${MODEL}")
      PASSED_COUNT=$((PASSED_COUNT + 1))
    else
      if command -v log_error &> /dev/null; then
        log_error "✗ FAILED: Test failed - $FAILURE_MSG" "provider=$PROVIDER" "model=$MODEL"
        increment_counter "tests_failed"
        record_metric "test_result" "failed" "provider=$PROVIDER" "model=$MODEL"
      else
        echo "✗ FAILED: Test failed - $FAILURE_MSG"
      fi
      RESULTS+=("✗ ${PROVIDER}: ${MODEL}")
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    
    if command -v end_span &> /dev/null; then
      end_span
    fi
    
    rm "$TMPFILE"
    rm -rf "$TESTDIR"
    echo "---"
  done
done

# Record final metrics
if command -v record_metric &> /dev/null; then
  record_metric "total_tests" "$((PASSED_COUNT + FAILED_COUNT))"
  record_metric "passed_tests" "$PASSED_COUNT"
  record_metric "failed_tests" "$FAILED_COUNT"
fi
echo ""
echo "=== Test Summary ==="
for result in "${RESULTS[@]}"; do
  echo "$result"
done

if echo "${RESULTS[@]}" | grep -q "✗"; then
  if command -v log_error &> /dev/null; then
    log_error "Some tests failed!" "passed=$PASSED_COUNT" "failed=$FAILED_COUNT"
  else
    echo ""
    echo "Some tests failed!"
  fi
  exit 1
else
  if command -v log_info &> /dev/null; then
    log_info "All tests passed!" "total=$((PASSED_COUNT + FAILED_COUNT))"
  else
    echo ""
    echo "All tests passed!"
  fi
fi
