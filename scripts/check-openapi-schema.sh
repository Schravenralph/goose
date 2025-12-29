#!/usr/bin/env bash
set -e

# Check if OpenAPI schema is up-to-date
# This script generates the OpenAPI schema and compares it with the committed version

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="check-openapi-schema"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

if command -v log_info &> /dev/null; then
  log_info "🔍 Checking OpenAPI schema is up-to-date..."
  start_span "check_openapi_schema"
  increment_counter "schema_checks"
else
  echo "🔍 Checking OpenAPI schema is up-to-date..."
fi

# Check if the generated schema differs from the committed version
if command -v log_info &> /dev/null; then
  log_info "Comparing generated schema with committed version..."
else
  echo "🔍 Comparing generated schema with committed version..."
fi

if ! git diff --ignore-space-change --exit-code ui/desktop/openapi.json ui/desktop/src/api/; then
  if command -v log_error &> /dev/null; then
    log_error "OpenAPI schema is out of date!"
    log_error "The generated OpenAPI schema differs from the committed version."
    log_error "This usually means that API types were added or modified without updating the schema."
    log_info "To fix: Run 'just generate-openapi', commit changes, and push"
    record_metric "schema_status" "out_of_date"
    increment_counter "schema_failures"
    end_span
  else
    echo ""
    echo "❌ OpenAPI schema is out of date!"
    echo ""
    echo "The generated OpenAPI schema differs from the committed version."
    echo "This usually means that API types were added or modified without updating the schema."
    echo ""
    echo "To fix this issue:"
    echo "1. Run 'just generate-openapi' locally"
    echo "2. Commit the changes to ui/desktop/openapi.json and ui/desktop/src/api/"
    echo "3. Push your changes"
    echo ""
    echo "Changes detected:"
    git diff ui/desktop/openapi.json ui/desktop/src/api/
  fi
  exit 1
fi

if command -v log_info &> /dev/null; then
  log_info "✅ OpenAPI schema is up-to-date"
  record_metric "schema_status" "up_to_date"
  increment_counter "schema_successes"
  end_span
else
  echo "✅ OpenAPI schema is up-to-date"
fi
