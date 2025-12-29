#!/bin/bash
# Enhanced TLS crate check with structured logging
# Prevent native-tls/OpenSSL from being added to the dependency tree.
# These cause Linux compatibility issues with OpenSSL version mismatches.
# See: https://github.com/block/goose/issues/6034

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="check-no-native-tls"

# Source logging utilities
source "$SCRIPT_DIR/logging-utils.sh"

BANNED_CRATES=("native-tls" "openssl-sys" "openssl")
FOUND_BANNED=0
TOTAL_CHECKED=0

start_span "tls_crate_check"
log_info "Checking for banned TLS crates: ${BANNED_CRATES[*]}"

for crate in "${BANNED_CRATES[@]}"; do
    ((TOTAL_CHECKED++))
    
    log_debug "Checking crate: $crate"
    
    if cargo tree -i "$crate" 2>/dev/null | grep -q "$crate"; then
        log_error "Found banned crate '$crate' in dependency tree"
        
        echo "This causes Linux compatibility issues with OpenSSL versions."
        echo "Use rustls-based alternatives instead (e.g., rustls-tls-native-roots)."
        echo ""
        echo "Dependency chain:"
        cargo tree -i "$crate"
        echo ""
        FOUND_BANNED=1
        
        record_metric "banned_crate_found" "1" "crate=$crate"
        increment_counter "banned_crates_found"
    else
        record_metric "banned_crate_found" "0" "crate=$crate"
    fi
done

record_metric "tls_check_total_crates" "$TOTAL_CHECKED"
record_metric "tls_check_banned_found" "$FOUND_BANNED"

if [ $FOUND_BANNED -eq 1 ]; then
    log_error "TLS crate check failed"
    end_span
    exit 1
fi

log_info "✓ No banned TLS crates found (native-tls, openssl, openssl-sys)"
record_metric "tls_check_success" "1"
end_span
