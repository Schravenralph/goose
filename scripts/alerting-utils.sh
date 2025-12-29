#!/bin/bash

# Alerting utilities for bash scripts
# Provides alerting capabilities for script failures, errors, and anomalies
# Integrates with structured logging infrastructure

# Alert configuration
ALERT_CONFIG_FILE="${ALERT_CONFIG_FILE:-${SCRIPT_DIR:-.}/alert-config.json}"
ALERT_DEDUP_FILE="${ALERT_DEDUP_FILE:-/tmp/goose-alerts-dedup.json}"
ALERT_LOG_FILE="${ALERT_LOG_FILE:-/tmp/goose-alerts/alert-log.jsonl}"
mkdir -p "$(dirname "$ALERT_LOG_FILE")" 2>/dev/null || true
mkdir -p "$(dirname "$ALERT_DEDUP_FILE")" 2>/dev/null || true

# Alert severity levels
SEVERITY_CRITICAL="CRITICAL"
SEVERITY_HIGH="HIGH"
SEVERITY_MEDIUM="MEDIUM"
SEVERITY_LOW="LOW"
SEVERITY_INFO="INFO"

# Default alert thresholds (can be overridden by config file)
DEFAULT_THRESHOLDS=(
    "ERROR_COUNT_THRESHOLD=1"
    "FAILURE_THRESHOLD=1"
    "DURATION_THRESHOLD=3600"  # 1 hour in seconds
    "REPEATED_FAILURE_COUNT=3"
    "ERROR_RATE_THRESHOLD=0.1"  # 10% error rate
)

# Load alert configuration if it exists
load_alert_config() {
    if [[ -f "$ALERT_CONFIG_FILE" ]] && command -v jq &> /dev/null; then
        # Load thresholds from config
        ERROR_COUNT_THRESHOLD=$(jq -r '.thresholds.error_count // 1' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "1")
        FAILURE_THRESHOLD=$(jq -r '.thresholds.failure // 1' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "1")
        DURATION_THRESHOLD=$(jq -r '.thresholds.duration_seconds // 3600' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "3600")
        REPEATED_FAILURE_COUNT=$(jq -r '.thresholds.repeated_failures // 3' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "3")
        ERROR_RATE_THRESHOLD=$(jq -r '.thresholds.error_rate // 0.1' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "0.1")
        
        # Load alert channels
        ALERT_EMAIL_ENABLED=$(jq -r '.channels.email.enabled // false' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "false")
        ALERT_EMAIL_TO=$(jq -r '.channels.email.to // ""' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "")
        ALERT_SLACK_ENABLED=$(jq -r '.channels.slack.enabled // false' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "false")
        ALERT_SLACK_WEBHOOK=$(jq -r '.channels.slack.webhook_url // ""' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "")
        ALERT_WEBHOOK_ENABLED=$(jq -r '.channels.webhook.enabled // false' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "false")
        ALERT_WEBHOOK_URL=$(jq -r '.channels.webhook.url // ""' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "")
        ALERT_PAGERDUTY_ENABLED=$(jq -r '.channels.pagerduty.enabled // false' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "false")
        ALERT_PAGERDUTY_KEY=$(jq -r '.channels.pagerduty.integration_key // ""' "$ALERT_CONFIG_FILE" 2>/dev/null || echo "")
    else
        # Use defaults
        ERROR_COUNT_THRESHOLD=1
        FAILURE_THRESHOLD=1
        DURATION_THRESHOLD=3600
        REPEATED_FAILURE_COUNT=3
        ERROR_RATE_THRESHOLD=0.1
        ALERT_EMAIL_ENABLED=false
        ALERT_SLACK_ENABLED=false
        ALERT_WEBHOOK_ENABLED=false
        ALERT_PAGERDUTY_ENABLED=false
    fi
}

# Initialize alert config on load
load_alert_config

# Generate alert ID for deduplication
generate_alert_id() {
    local alert_type="$1"
    local script_name="${2:-unknown}"
    local context="${3:-}"
    echo "${alert_type}_${script_name}_${context}" | sha256sum | cut -d' ' -f1 | head -c 16
}

# Check if alert should be deduplicated
should_deduplicate_alert() {
    local alert_id="$1"
    local dedup_window="${2:-300}"  # 5 minutes default
    
    if [[ ! -f "$ALERT_DEDUP_FILE" ]]; then
        echo "{}" > "$ALERT_DEDUP_FILE"
    fi
    
    # Check if alert was sent recently
    if command -v jq &> /dev/null; then
        local last_sent=$(jq -r --arg id "$alert_id" '.[$id] // 0' "$ALERT_DEDUP_FILE" 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_sent))
        
        if [[ $time_diff -lt $dedup_window ]]; then
            return 0  # Should deduplicate
        fi
    else
        # Simple grep-based deduplication if jq not available
        if grep -q "$alert_id" "$ALERT_DEDUP_FILE" 2>/dev/null; then
            return 0  # Should deduplicate
        fi
    fi
    
    return 1  # Should not deduplicate
}

# Record alert in deduplication file
record_alert_sent() {
    local alert_id="$1"
    local current_time=$(date +%s)
    
    if command -v jq &> /dev/null; then
        if [[ ! -f "$ALERT_DEDUP_FILE" ]]; then
            echo "{}" > "$ALERT_DEDUP_FILE"
        fi
        local temp_file=$(mktemp)
        jq --arg id "$alert_id" --arg time "$current_time" '.[$id] = ($time | tonumber)' "$ALERT_DEDUP_FILE" > "$temp_file" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            mv "$temp_file" "$ALERT_DEDUP_FILE"
        fi
    else
        # Simple append if jq not available
        echo "$alert_id:$current_time" >> "$ALERT_DEDUP_FILE"
    fi
}

# Log alert to alert log file
log_alert() {
    local severity="$1"
    local alert_type="$2"
    local message="$3"
    local context="${4:-{}}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    local script_name="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    local trace_id="${TRACE_ID:-unknown}"
    
    local log_entry
    if command -v jq &> /dev/null; then
        log_entry=$(jq -n \
            --arg timestamp "$timestamp" \
            --arg severity "$severity" \
            --arg alert_type "$alert_type" \
            --arg script "$script_name" \
            --arg trace_id "$trace_id" \
            --arg message "$message" \
            --argjson context "$context" \
            '{
                timestamp: $timestamp,
                severity: $severity,
                alert_type: $alert_type,
                script: $script,
                trace_id: $trace_id,
                message: $message,
                context: $context
            }' 2>/dev/null)
    else
        log_entry="{\"timestamp\":\"$timestamp\",\"severity\":\"$severity\",\"alert_type\":\"$alert_type\",\"script\":\"$script_name\",\"trace_id\":\"$trace_id\",\"message\":\"$message\",\"context\":$context}"
    fi
    
    echo "$log_entry" >> "$ALERT_LOG_FILE" 2>/dev/null || true
}

# Send alert via email
send_email_alert() {
    local severity="$1"
    local subject="$2"
    local body="$3"
    
    if [[ "$ALERT_EMAIL_ENABLED" != "true" ]] || [[ -z "$ALERT_EMAIL_TO" ]]; then
        return 0
    fi
    
    # Try to use mail command if available
    if command -v mail &> /dev/null; then
        echo "$body" | mail -s "$subject" "$ALERT_EMAIL_TO" 2>/dev/null || true
    elif command -v sendmail &> /dev/null; then
        {
            echo "To: $ALERT_EMAIL_TO"
            echo "Subject: $subject"
            echo ""
            echo "$body"
        } | sendmail "$ALERT_EMAIL_TO" 2>/dev/null || true
    else
        log_alert "$SEVERITY_LOW" "email_alert_failed" "Email alert requested but mail/sendmail not available" "{\"severity\":\"$severity\"}"
    fi
}

# Send alert via Slack
send_slack_alert() {
    local severity="$1"
    local message="$2"
    local context="${3:-{}}"
    
    if [[ "$ALERT_SLACK_ENABLED" != "true" ]] || [[ -z "$ALERT_SLACK_WEBHOOK" ]]; then
        return 0
    fi
    
    # Determine color based on severity
    local color="good"
    case "$severity" in
        "$SEVERITY_CRITICAL")
            color="danger"
            ;;
        "$SEVERITY_HIGH")
            color="warning"
            ;;
        "$SEVERITY_MEDIUM")
            color="warning"
            ;;
        *)
            color="good"
            ;;
    esac
    
    local script_name="${SCRIPT_NAME:-unknown}"
    local trace_id="${TRACE_ID:-unknown}"
    
    local payload
    if command -v jq &> /dev/null; then
        payload=$(jq -n \
            --arg text "$message" \
            --arg color "$color" \
            --arg script "$script_name" \
            --arg trace_id "$trace_id" \
            --arg severity "$severity" \
            --argjson context "$context" \
            '{
                attachments: [{
                    color: $color,
                    title: "Goose Alert: \($severity)",
                    text: $text,
                    fields: [
                        {title: "Script", value: $script, short: true},
                        {title: "Trace ID", value: $trace_id, short: true},
                        {title: "Context", value: ($context | tostring), short: false}
                    ],
                    ts: (now | tostring)
                }]
            }' 2>/dev/null)
    else
        payload="{\"text\":\"$message\",\"attachments\":[{\"color\":\"$color\",\"title\":\"Goose Alert: $severity\",\"text\":\"$message\"}]}"
    fi
    
    curl -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$ALERT_SLACK_WEBHOOK" \
        >/dev/null 2>&1 || true
}

# Send alert via generic webhook
send_webhook_alert() {
    local severity="$1"
    local message="$2"
    local context="${3:-{}}"
    
    if [[ "$ALERT_WEBHOOK_ENABLED" != "true" ]] || [[ -z "$ALERT_WEBHOOK_URL" ]]; then
        return 0
    fi
    
    local script_name="${SCRIPT_NAME:-unknown}"
    local trace_id="${TRACE_ID:-unknown}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    local payload
    if command -v jq &> /dev/null; then
        payload=$(jq -n \
            --arg severity "$severity" \
            --arg message "$message" \
            --arg script "$script_name" \
            --arg trace_id "$trace_id" \
            --arg timestamp "$timestamp" \
            --argjson context "$context" \
            '{
                severity: $severity,
                message: $message,
                script: $script,
                trace_id: $trace_id,
                timestamp: $timestamp,
                context: $context
            }' 2>/dev/null)
    else
        payload="{\"severity\":\"$severity\",\"message\":\"$message\",\"script\":\"$script_name\",\"trace_id\":\"$trace_id\",\"timestamp\":\"$timestamp\",\"context\":$context}"
    fi
    
    curl -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$ALERT_WEBHOOK_URL" \
        >/dev/null 2>&1 || true
}

# Send alert via PagerDuty
send_pagerduty_alert() {
    local severity="$1"
    local message="$2"
    local context="${3:-{}}"
    
    if [[ "$ALERT_PAGERDUTY_ENABLED" != "true" ]] || [[ -z "$ALERT_PAGERDUTY_KEY" ]]; then
        return 0
    fi
    
    # Map severity to PagerDuty severity
    local pd_severity="info"
    case "$severity" in
        "$SEVERITY_CRITICAL")
            pd_severity="critical"
            ;;
        "$SEVERITY_HIGH")
            pd_severity="error"
            ;;
        "$SEVERITY_MEDIUM")
            pd_severity="warning"
            ;;
        *)
            pd_severity="info"
            ;;
    esac
    
    local script_name="${SCRIPT_NAME:-unknown}"
    local trace_id="${TRACE_ID:-unknown}"
    local dedup_key=$(echo "${script_name}_${trace_id}" | sha256sum | cut -d' ' -f1 | head -c 32)
    
    local payload
    if command -v jq &> /dev/null; then
        payload=$(jq -n \
            --arg routing_key "$ALERT_PAGERDUTY_KEY" \
            --arg dedup_key "$dedup_key" \
            --arg severity "$pd_severity" \
            --arg summary "$message" \
            --arg script "$script_name" \
            --arg trace_id "$trace_id" \
            --argjson context "$context" \
            '{
                routing_key: $routing_key,
                dedup_key: $dedup_key,
                event_action: "trigger",
                payload: {
                    summary: $summary,
                    severity: $severity,
                    source: $script,
                    custom_details: {
                        script: $script,
                        trace_id: $trace_id,
                        context: $context
                    }
                }
            }' 2>/dev/null)
    else
        payload="{\"routing_key\":\"$ALERT_PAGERDUTY_KEY\",\"event_action\":\"trigger\",\"payload\":{\"summary\":\"$message\",\"severity\":\"$pd_severity\"}}"
    fi
    
    curl -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "https://events.pagerduty.com/v2/enqueue" \
        >/dev/null 2>&1 || true
}

# Send alert to all configured channels
send_alert() {
    local severity="$1"
    local alert_type="$2"
    local message="$3"
    local context="${4:-{}}"
    local dedup="${5:-true}"
    
    local script_name="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    local alert_id=$(generate_alert_id "$alert_type" "$script_name" "$context")
    
    # Check deduplication
    if [[ "$dedup" == "true" ]] && should_deduplicate_alert "$alert_id"; then
        return 0  # Alert already sent recently, skip
    fi
    
    # Log the alert
    log_alert "$severity" "$alert_type" "$message" "$context"
    
    # Send to all configured channels
    send_email_alert "$severity" "[$severity] Goose Alert: $alert_type" "$message\n\nContext: $context"
    send_slack_alert "$severity" "$message" "$context"
    send_webhook_alert "$severity" "$message" "$context"
    send_pagerduty_alert "$severity" "$message" "$context"
    
    # Record that alert was sent
    record_alert_sent "$alert_id"
}

# Check for script failure and send alert
check_script_failure() {
    local exit_code="${1:-0}"
    local script_name="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    
    if [[ $exit_code -ne 0 ]]; then
        local severity="$SEVERITY_CRITICAL"
        if [[ $exit_code -eq 1 ]]; then
            severity="$SEVERITY_HIGH"
        fi
        
        local context
        if command -v jq &> /dev/null; then
            context=$(jq -n \
                --arg exit_code "$exit_code" \
                --arg script "$script_name" \
                '{
                    exit_code: ($exit_code | tonumber),
                    script: $script,
                    failure_type: "script_exit"
                }' 2>/dev/null || echo "{\"exit_code\":$exit_code}")
        else
            context="{\"exit_code\":$exit_code,\"script\":\"$script_name\"}"
        fi
        
        send_alert "$severity" "script_failure" \
            "Script '$script_name' failed with exit code $exit_code" \
            "$context"
    fi
}

# Check for high error count in logs
check_error_count() {
    local log_file="${1:-}"
    local error_count="${2:-0}"
    
    if [[ -z "$log_file" ]] || [[ ! -f "$log_file" ]]; then
        return 0
    fi
    
    if [[ $error_count -ge $ERROR_COUNT_THRESHOLD ]]; then
        local severity="$SEVERITY_HIGH"
        if [[ $error_count -ge 10 ]]; then
            severity="$SEVERITY_CRITICAL"
        fi
        
        local context
        if command -v jq &> /dev/null; then
            context=$(jq -n \
                --arg error_count "$error_count" \
                --arg threshold "$ERROR_COUNT_THRESHOLD" \
                '{
                    error_count: ($error_count | tonumber),
                    threshold: ($threshold | tonumber),
                    log_file: $log_file
                }' 2>/dev/null || echo "{\"error_count\":$error_count}")
        else
            context="{\"error_count\":$error_count,\"threshold\":$ERROR_COUNT_THRESHOLD}"
        fi
        
        send_alert "$severity" "high_error_count" \
            "High error count detected: $error_count errors (threshold: $ERROR_COUNT_THRESHOLD)" \
            "$context"
    fi
}

# Check for performance degradation
check_performance_degradation() {
    local duration="${1:-0}"
    local script_name="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    
    if (( $(echo "$duration > $DURATION_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        local context
        if command -v jq &> /dev/null; then
            context=$(jq -n \
                --arg duration "$duration" \
                --arg threshold "$DURATION_THRESHOLD" \
                --arg script "$script_name" \
                '{
                    duration: ($duration | tonumber),
                    threshold: ($threshold | tonumber),
                    script: $script
                }' 2>/dev/null || echo "{\"duration\":$duration}")
        else
            context="{\"duration\":$duration,\"threshold\":$DURATION_THRESHOLD}"
        fi
        
        send_alert "$SEVERITY_MEDIUM" "performance_degradation" \
            "Script '$script_name' took ${duration}s (threshold: ${DURATION_THRESHOLD}s)" \
            "$context"
    fi
}

# Check for repeated failures
check_repeated_failures() {
    local script_name="${1:-${SCRIPT_NAME:-unknown}}"
    local failure_count="${2:-0}"
    
    if [[ $failure_count -ge $REPEATED_FAILURE_COUNT ]]; then
        local context
        if command -v jq &> /dev/null; then
            context=$(jq -n \
                --arg failure_count "$failure_count" \
                --arg threshold "$REPEATED_FAILURE_COUNT" \
                --arg script "$script_name" \
                '{
                    failure_count: ($failure_count | tonumber),
                    threshold: ($threshold | tonumber),
                    script: $script
                }' 2>/dev/null || echo "{\"failure_count\":$failure_count}")
        else
            context="{\"failure_count\":$failure_count,\"threshold\":$REPEATED_FAILURE_COUNT}"
        fi
        
        send_alert "$SEVERITY_CRITICAL" "repeated_failures" \
            "Script '$script_name' has failed $failure_count times (threshold: $REPEATED_FAILURE_COUNT)" \
            "$context"
    fi
}

# Analyze metrics file and check for anomalies
analyze_metrics_and_alert() {
    local metrics_file="${1:-}"
    
    if [[ -z "$metrics_file" ]] || [[ ! -f "$metrics_file" ]]; then
        return 0
    fi
    
    if ! command -v jq &> /dev/null; then
        return 0  # Can't analyze without jq
    fi
    
    local exit_code=$(jq -r '.exit_code // 0' "$metrics_file" 2>/dev/null || echo "0")
    local duration=$(jq -r '.duration // 0' "$metrics_file" 2>/dev/null || echo "0")
    
    # Check for failure
    if [[ $exit_code -ne 0 ]]; then
        check_script_failure "$exit_code"
    fi
    
    # Check for performance issues
    if (( $(echo "$duration > 0" | bc -l 2>/dev/null || echo "0") )); then
        check_performance_degradation "$duration"
    fi
    
    # Check for error-related metrics
    local error_count=0
    for key in $(jq -r 'keys[]' "$metrics_file" 2>/dev/null); do
        if [[ "$key" =~ error|Error|ERROR ]]; then
            local value=$(jq -r --arg key "$key" '.[$key]' "$metrics_file" 2>/dev/null || echo "0")
            if [[ "$value" =~ ^[0-9]+$ ]] && [[ $value -gt 0 ]]; then
                error_count=$((error_count + value))
            fi
        fi
    done
    
    if [[ $error_count -gt 0 ]]; then
        check_error_count "$metrics_file" "$error_count"
    fi
}

