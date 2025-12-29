#!/bin/bash
# Test MCP sampling functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="test_mcp"

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

# Initialize metrics
if command -v increment_counter &> /dev/null; then
    increment_counter "total_mcp_test_runs"
fi

JUDGE_PROVIDER=${GOOSE_JUDGE_PROVIDER:-openrouter}
JUDGE_MODEL=${GOOSE_JUDGE_MODEL:-google/gemini-2.5-flash}

PROVIDERS=(
  #"google:gemini-2.5-pro"
  "anthropic:claude-haiku-4-5-20251001"
  #"openrouter:google/gemini-2.5-pro"
  #"openai:gpt-5-mini"
)

# In CI, only run Databricks tests if DATABRICKS_HOST and DATABRICKS_TOKEN are set
# Locally, always run Databricks tests
if [ -n "$CI" ]; then
  if [ -n "$DATABRICKS_HOST" ] && [ -n "$DATABRICKS_TOKEN" ]; then
    if command -v log_info &> /dev/null; then
      log_info "Including Databricks tests"
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
    log_info "Including Databricks tests"
  else
    echo "✓ Including Databricks tests"
  fi
  PROVIDERS+=("databricks:databricks-claude-sonnet-4:gemini-2-5-flash:gpt-4o")
fi

if command -v start_span &> /dev/null; then
    start_span "mcp_tests"
fi

RESULTS=()
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

for provider_config in "${PROVIDERS[@]}"; do
  IFS=':' read -ra PARTS <<< "$provider_config"
  PROVIDER="${PARTS[0]}"
  for i in $(seq 1 $((${#PARTS[@]} - 1))); do
    MODEL="${PARTS[$i]}"
    export GOOSE_PROVIDER="$PROVIDER"
    export GOOSE_MODEL="$MODEL"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if command -v start_span &> /dev/null; then
        start_span "test_mcp_${PROVIDER}_${MODEL}"
    fi
    
    TESTDIR=$(mktemp -d)
    
    if command -v log_info &> /dev/null; then
      log_info "Testing MCP sampling" "provider=$PROVIDER" "model=$MODEL"
    else
      echo "Provider: ${PROVIDER}"
      echo "Model: ${MODEL}"
      echo ""
    fi
    
    TMPFILE=$(mktemp)
    (cd "$TESTDIR" && "$SCRIPT_DIR/target/release/goose" run --text "Use the sampleLLM tool to ask for a quote from The Great Gatsby" --with-extension "npx -y @modelcontextprotocol/server-everything" 2>&1) | tee "$TMPFILE"
    echo ""
    if grep -q "sampleLLM | " "$TMPFILE"; then

      JUDGE_PROMPT=$(cat <<EOF
You are a validator. You will be given a transcript of a CLI run that used an MCP tool to initiate MCP sampling.
The MCP server requests a quote from The Great Gatsby from the model via sampling.

Task: Determine whether the transcript shows that the sampling request reached the model and that the output included either:
  • A recognizable quote, paraphrase, or reference from The Great Gatsby, or
  • A clear attempt or explanation from the model about why the quote could not be returned.

If either of these conditions is true, respond PASS.
If there is no evidence that the model attempted or returned a Gatsby-related response, respond FAIL.
If uncertain, lean toward PASS.

Output format: Respond with exactly one word on a single line:
PASS
or
FAIL

Transcript:
----- BEGIN TRANSCRIPT -----
$(cat "$TMPFILE")
----- END TRANSCRIPT -----
EOF
)
      JUDGE_OUT=$(GOOSE_PROVIDER="$JUDGE_PROVIDER" GOOSE_MODEL="$JUDGE_MODEL" \
        "$SCRIPT_DIR/target/release/goose" run --text "$JUDGE_PROMPT" 2>&1)

      if echo "$JUDGE_OUT" | tr -d '\r' | grep -Eq '^[[:space:]]*PASS[[:space:]]*$'; then
        if command -v log_info &> /dev/null; then
          log_info "MCP sampling test passed" "provider=$PROVIDER" "model=$MODEL" "judge=$JUDGE_PROVIDER:$JUDGE_MODEL"
          increment_counter "mcp_tests_passed"
          record_metric "mcp_test_result" "passed" "provider=$PROVIDER" "model=$MODEL"
        else
          echo "✓ SUCCESS: MCP sampling test passed - confirmed Gatsby related response"
        fi
        RESULTS+=("✓ MCP Sampling ${PROVIDER}: ${MODEL}")
        PASSED_TESTS=$((PASSED_TESTS + 1))
      else
        if command -v log_error &> /dev/null; then
          log_error "MCP sampling test failed" "provider=$PROVIDER" "model=$MODEL" "judge=$JUDGE_PROVIDER:$JUDGE_MODEL"
          increment_counter "mcp_tests_failed"
          record_metric "mcp_test_result" "failed" "provider=$PROVIDER" "model=$MODEL"
        else
          echo "✗ FAILED: MCP sampling test failed - did not confirm Gatsby related response"
          echo "  Judge provider/model: ${JUDGE_PROVIDER}:${JUDGE_MODEL}"
          echo "  Judge output (snippet):"
          echo "$JUDGE_OUT" | tail -n 20
        fi
        RESULTS+=("✗ MCP Sampling ${PROVIDER}: ${MODEL}")
        FAILED_TESTS=$((FAILED_TESTS + 1))
      fi
    else
      if command -v log_error &> /dev/null; then
        log_error "MCP sampling test failed - sampleLLM tool not called" "provider=$PROVIDER" "model=$MODEL"
        increment_counter "mcp_tests_failed"
        record_metric "mcp_test_result" "failed" "provider=$PROVIDER" "model=$MODEL" "reason=tool_not_called"
      else
        echo "✗ FAILED: MCP sampling test failed - sampleLLM tool not called"
      fi
      RESULTS+=("✗ MCP Sampling ${PROVIDER}: ${MODEL}")
      FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    if command -v end_span &> /dev/null; then
        end_span
    fi
    
    rm "$TMPFILE"
    rm -rf "$TESTDIR"
    
    if command -v log_debug &> /dev/null; then
      log_debug "Test completed" "provider=$PROVIDER" "model=$MODEL"
    else
      echo "---"
    fi
  done
done

if command -v end_span &> /dev/null; then
    end_span
    record_metric "total_mcp_tests" "$TOTAL_TESTS"
    record_metric "passed_mcp_tests" "$PASSED_TESTS"
    record_metric "failed_mcp_tests" "$FAILED_TESTS"
    if [ "$TOTAL_TESTS" -gt 0 ]; then
      record_metric "mcp_success_rate" "$(awk "BEGIN {printf \"%.2f\", ($PASSED_TESTS / $TOTAL_TESTS) * 100}" 2>/dev/null || echo "0")"
    fi
fi

if command -v log_info &> /dev/null; then
  log_info "MCP Sampling Test Summary" "total=$TOTAL_TESTS" "passed=$PASSED_TESTS" "failed=$FAILED_TESTS"
else
  echo ""
  echo "=== MCP Sampling Test Summary ==="
fi

for result in "${RESULTS[@]}"; do
  echo "$result"
done

if echo "${RESULTS[@]}" | grep -q "✗"; then
  if command -v log_error &> /dev/null; then
    log_error "Some MCP sampling tests failed!" "failed_count=$FAILED_TESTS"
  else
    echo ""
    echo "Some MCP sampling tests failed!"
  fi
  exit 1
else
  if command -v log_info &> /dev/null; then
    log_info "All MCP sampling tests passed!" "total=$TOTAL_TESTS"
  else
    echo ""
    echo "All MCP sampling tests passed!"
  fi
fi
