#!/bin/bash

# Enhanced baseline clippy rules with structured logging
# Only fail on NEW violations

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="clippy-baseline"

# Source logging utilities
source "$SCRIPT_DIR/logging-utils.sh"

# Format: "rule_name|violation_parser"
#
# Violation parsers (run clippy on your rule to see which fits):
#   function_name - When spans show: "fn my_function(..."
#   type_name     - When spans show: "struct MyStruct" or "enum MyEnum"
#   file_only     - When spans show file-level issues
#
# Note: If your rule doesn't fit these parsers, you may need to add a new parser
# to the parse_violation() function below
#
# To add new rules:
# 1. Add rule below: "clippy::your_rule|violation_parser"
# 2. Generate baseline: ./scripts/clippy-baseline.sh generate clippy::your_rule

BASELINE_RULES=(
    "clippy::too_many_lines|function_name"
)

parse_violation() {
    local rule_code="$1"
    local violation_parser="$2"

    case "$violation_parser" in
        "function_name")
            jq -r 'select(.message.code.code == "'"$rule_code"'") |
                   "\(.message.spans[0].file_name)::\(.message.spans[0].text[0].text | split("fn ")[1] | split("(")[0])"' 2>/dev/null || echo ""
            ;;
        "type_name")
            jq -r 'select(.message.code.code == "'"$rule_code"'") |
                   "\(.message.spans[0].file_name)::\(.message.spans[0].text[0].text | split(" ")[1] | split(" ")[0])"' 2>/dev/null || echo ""
            ;;
        "file_only")
            jq -r 'select(.message.code.code == "'"$rule_code"'") |
                   "\(.message.spans[0].file_name)"' 2>/dev/null || echo ""
            ;;
        *)
            log_error "Unknown violation parser: $violation_parser"
            exit 1
            ;;
    esac
}

get_baseline_file() {
    local rule_name="$1"
    local safe_name=$(echo "$rule_name" | sed 's/clippy:://' | sed 's/:/-/g')
    echo "clippy-baselines/${safe_name}.txt"
}


generate_baseline() {
    local rule_name="$1"

    [[ -z "$rule_name" ]] && { 
        log_error "Missing rule name"
        return 1
    }

    local violation_parser=""
    for rule in "${BASELINE_RULES[@]}"; do
        [[ "${rule%|*}" == "$rule_name" ]] && { violation_parser="${rule#*|}"; break; }
    done

    [[ -z "$violation_parser" ]] && { 
        log_error "Unknown rule: $rule_name"
        return 1
    }

    local baseline_file=$(get_baseline_file "$rule_name")
    
    log_info "Generating baseline for: $rule_name"
    start_span "generate_baseline_$rule_name"

    cargo clippy --jobs 2 --message-format=json -- -W "$rule_name" 2>/dev/null | \
        parse_violation "$rule_name" "$violation_parser" | \
        sort > "$baseline_file"

    local violation_count=$(wc -l < "$baseline_file" 2>/dev/null || echo "0")
    
    log_info "✅ Generated baseline for $rule_name" "violations=$violation_count"
    record_metric "baseline_generated" "1" "rule=$rule_name" "violations=$violation_count"
    end_span
}


# Check a single rule from pre-generated JSON (optimized version)
check_rule_from_json() {
    local temp_json="$1"
    local rule_name="$2"
    local violation_parser="$3"
    local baseline_file="$4"

    log_debug "  → Checking $rule_name"

    if [[ ! -f "$baseline_file" ]]; then
        log_error "  ❌ $rule_name: baseline file not found"
        return 1
    fi

    local temp_parsed=$(mktemp)
    cat "$temp_json" | parse_violation "$rule_name" "$violation_parser" | sort > "$temp_parsed" 2>/dev/null

    local new_violations_file=$(mktemp)
    diff <(sort "$baseline_file") <(sort "$temp_parsed") 2>/dev/null | grep "^>" | cut -c3- > "$new_violations_file"

    if [[ -s "$new_violations_file" ]]; then
        local violation_count=$(wc -l < "$new_violations_file" 2>/dev/null || echo "0")
        
        log_error "  ❌ $rule_name: NEW violations found" "count=$violation_count"

        while IFS= read -r violation; do
            # Extract all violations for this rule and find the matching one
            cat "$temp_json" | jq -c 'select(.message.code.code == "'"$rule_name"'")' 2>/dev/null | while read -r json_line; do
                parsed_id=$(echo "$json_line" | parse_violation "$rule_name" "$violation_parser")
                if [[ "$parsed_id" == "$violation" ]]; then
                    local rendered=$(echo "$json_line" | jq -r '.message.rendered' 2>/dev/null)
                    log_error "    $rendered"
                fi
            done
        done < "$new_violations_file"

        rm "$temp_parsed" "$new_violations_file"
        
        record_metric "baseline_rule_failed" "1" "rule=$rule_name" "violations=$violation_count"
        
        return 1
    fi

    rm "$new_violations_file"

    log_info "  ✅ $rule_name: ok"
    record_metric "baseline_rule_passed" "1" "rule=$rule_name"
    
    rm "$temp_parsed"
    return 0
}

check_all_baseline_rules() {
    log_info "🔍 Checking baseline clippy rules..."
    start_span "baseline_rules_check"

    local clippy_flags=""
    for rule in "${BASELINE_RULES[@]}"; do
        local rule_name="${rule%|*}"
        clippy_flags="$clippy_flags -W $rule_name"
    done

    local temp_json=$(mktemp)
    cargo clippy --jobs 2 --message-format=json -- $clippy_flags 2>/dev/null | tee "$temp_json" > /dev/null

    local failed_rules=()
    local total_rules=${#BASELINE_RULES[@]}
    local passed_rules=0

    # Check each rule against its baseline
    for rule in "${BASELINE_RULES[@]}"; do
        local rule_name="${rule%|*}"
        local violation_parser="${rule#*|}"
        local baseline_file=$(get_baseline_file "$rule_name")

        if check_rule_from_json "$temp_json" "$rule_name" "$violation_parser" "$baseline_file"; then
            ((passed_rules++))
        else
            failed_rules+=("$rule_name")
        fi
    done

    rm "$temp_json"

    if command -v record_metric &> /dev/null; then
        record_metric "baseline_rules_total" "$total_rules"
        record_metric "baseline_rules_passed" "$passed_rules"
        record_metric "baseline_rules_failed" "${#failed_rules[@]}"
    fi

    if [[ ${#failed_rules[@]} -gt 0 ]]; then
        log_error "❌ Failed baseline checks for: ${failed_rules[*]}"
        end_span
        exit 1
    else
        log_info "✅ All baseline clippy checks passed!"
        end_span
    fi
}

if [[ "$1" == "generate" ]]; then
    generate_baseline "$2"
fi
