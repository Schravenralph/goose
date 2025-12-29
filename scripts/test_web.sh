#!/bin/bash
# Test script for Goose Web Interface

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="test_web"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

if command -v log_info &> /dev/null; then
  log_info "Testing Goose Web Interface"
  start_span "web_interface_test"
  increment_counter "web_test_runs"
else
  echo "Testing Goose Web Interface..."
  echo "================================"
fi

# Start the web server in the background
if command -v log_info &> /dev/null; then
  log_info "Starting web server" "port=8080"
  start_span "start_web_server"
else
  echo "Starting web server on port 8080..."
fi

./target/debug/goose web --port 8080 &
SERVER_PID=$!

if command -v record_metric &> /dev/null; then
  record_metric "server_pid" "$SERVER_PID"
  record_metric "server_port" "8080"
fi

# Wait for server to start
sleep 2

if command -v end_span &> /dev/null; then
  end_span
fi

# Test the health endpoint
if command -v log_info &> /dev/null; then
  log_info "Testing health endpoint"
  start_span "health_check"
else
  echo -e "\nTesting health endpoint:"
fi

if curl -s http://localhost:8080/api/health | jq .; then
  if command -v log_info &> /dev/null; then
    log_info "Health check passed"
    record_metric "health_check_success" "1"
    increment_counter "health_check_successes"
  fi
else
  if command -v log_error &> /dev/null; then
    log_error "Health check failed"
    record_metric "health_check_success" "0"
    increment_counter "health_check_failures"
  fi
fi

if command -v end_span &> /dev/null; then
  end_span
fi

# Open browser (optional)
# open http://localhost:8080

if command -v log_info &> /dev/null; then
  log_info "Web server is running" "url=http://localhost:8080" "pid=$SERVER_PID"
else
  echo -e "\nWeb server is running at http://localhost:8080"
  echo "Press Ctrl+C to stop the server"
fi

# Wait for user to stop
wait $SERVER_PID

if command -v log_info &> /dev/null; then
  log_info "Web server stopped"
  end_span
fi