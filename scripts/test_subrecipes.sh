#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="test_subrecipes"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
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

if command -v log_info &> /dev/null; then
  log_info "🚀 Starting subrecipe tests"
  start_span "subrecipe_tests"
  increment_counter "subrecipe_test_runs"
fi

# Add goose binary to PATH so subagents can find it when spawning
export PATH="$SCRIPT_DIR/target/release:$PATH"

# Set default provider and model if not already set
# Use fast model for CI to speed up tests
export GOOSE_PROVIDER="${GOOSE_PROVIDER:-anthropic}"
export GOOSE_MODEL="${GOOSE_MODEL:-claude-3-5-haiku-20241022}"

if command -v log_info &> /dev/null; then
  log_info "Configuration" "provider=$GOOSE_PROVIDER" "model=$GOOSE_MODEL"
  record_metric "provider" "$GOOSE_PROVIDER"
  record_metric "model" "$GOOSE_MODEL"
else
  echo "Using provider: $GOOSE_PROVIDER"
  echo "Using model: $GOOSE_MODEL"
  echo ""
fi

TESTDIR=$(mktemp -d)
if command -v log_info &> /dev/null; then
  log_info "Created test directory" "dir=$TESTDIR"
else
  echo "Created test directory: $TESTDIR"
fi

cp -r "$SCRIPT_DIR/scripts/test-subrecipes-examples/"* "$TESTDIR/"
if command -v log_info &> /dev/null; then
  log_info "Copied test recipes from scripts/test-subrecipes-examples"
else
  echo "Copied test recipes from scripts/test-subrecipes-examples"
fi

if command -v log_info &> /dev/null; then
  log_info "Testing Subrecipe Workflow" "recipe=$TESTDIR/project_analyzer.yaml"
else
  echo ""
  echo "=== Testing Subrecipe Workflow ==="
  echo "Recipe: $TESTDIR/project_analyzer.yaml"
  echo ""
fi

# Create sample code files for analysis
echo "Creating sample code files for testing..."
cat > "$TESTDIR/sample.rs" << 'EOF'
// TODO: Add error handling
fn calculate(x: i32, y: i32) -> i32 {
    x + y
}

#[test]
fn test_calculate() {
    assert_eq!(calculate(2, 2), 4);
}
EOF

cat > "$TESTDIR/sample.py" << 'EOF'
# FIXME: Optimize this function
def process_data(items):
    """Process a list of items"""
    return [item * 2 for item in items]

def test_process_data():
    assert process_data([1, 2, 3]) == [2, 4, 6]
EOF

cat > "$TESTDIR/README.md" << 'EOF'
# Sample Project
This is a test project for analyzing code patterns.
## TODO
- Add more tests
EOF
echo ""

RESULTS=()

check_recipe_output() {
  local tmpfile=$1
  local mode=$2
  
  # Check for unified subagent tool invocation (new format: "─── subagent |")
  if grep -q "─── subagent" "$tmpfile"; then
    echo "✓ SUCCESS: Subagent tool invoked"
    RESULTS+=("✓ Subagent tool invocation ($mode)")
  else
    echo "✗ FAILED: No evidence of subagent tool invocation"
    RESULTS+=("✗ Subagent tool invocation ($mode)")
  fi
  
  # Check that both subrecipes were called (shown as "subrecipe: <name>" in output)
  if grep -q "subrecipe:.*file_stats\|file_stats.*subrecipe" "$tmpfile" && grep -q "subrecipe:.*code_patterns\|code_patterns.*subrecipe" "$tmpfile"; then
    echo "✓ SUCCESS: Both subrecipes (file_stats, code_patterns) found in output"
    RESULTS+=("✓ Both subrecipes present ($mode)")
  else
    echo "✗ FAILED: Not all subrecipes found in output"
    RESULTS+=("✗ Subrecipe names ($mode)")
  fi
}

echo "Running recipe with parallel subrecipes..."
TMPFILE=$(mktemp)
if (cd "$TESTDIR" && "$SCRIPT_DIR/target/release/goose" run --recipe project_analyzer_parallel.yaml --no-session 2>&1) | tee "$TMPFILE"; then
  echo "✓ SUCCESS: Recipe completed successfully"
  RESULTS+=("✓ Recipe exit code")
  check_recipe_output "$TMPFILE" "parallel"
else
  echo "✗ FAILED: Recipe execution failed"
  RESULTS+=("✗ Recipe exit code")
fi
rm "$TMPFILE"
echo ""

rm -rf "$TESTDIR"

echo "=== Test Summary ==="
for result in "${RESULTS[@]}"; do
  echo "$result"
done

if echo "${RESULTS[@]}" | grep -q "✗"; then
  echo ""
  echo "Some tests failed!"
  exit 1
else
  echo ""
  echo "All tests passed!"
fi
