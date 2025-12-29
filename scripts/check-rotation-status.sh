#!/bin/bash

# Script to check log rotation status
# Queries the rotation status file and displays current status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
BASH_LOG_DIR="${LOG_DIR:-/tmp/goose-logs}"
ROTATION_STATUS_FILE="${ROTATION_STATUS_FILE:-$BASH_LOG_DIR/.rotation-status.json}"

# Function to display status
display_status() {
    if [[ ! -f "$ROTATION_STATUS_FILE" ]]; then
        echo "Rotation status file not found: $ROTATION_STATUS_FILE"
        echo "Log rotation may not have run yet."
        return 1
    fi
    
    if command -v jq &> /dev/null; then
        # Pretty print with jq
        echo "=== Log Rotation Status ==="
        echo
        jq -r '
            "Last Rotation: " + (.last_rotation_time | strftime("%Y-%m-%d %H:%M:%S UTC") // "unknown"),
            "Duration: " + (.duration_seconds | tostring) + " seconds",
            "Success: " + (.success | tostring),
            "Files Compressed: " + (.files_compressed | tostring),
            "Files Deleted: " + (.files_deleted | tostring),
            "Files Archived: " + (.files_archived | tostring),
            "Space Freed: " + ((.space_freed_bytes / 1024 / 1024) | floor | tostring) + " MB",
            "Disk Usage: " + (.disk_usage_percent | tostring) + "%",
            "Available Disk Space: " + (.available_disk_space_mb | tostring) + " MB"
        ' "$ROTATION_STATUS_FILE" 2>/dev/null || {
            echo "Error parsing status file"
            cat "$ROTATION_STATUS_FILE"
        }
    else
        # Fallback: simple display
        echo "=== Log Rotation Status ==="
        echo
        cat "$ROTATION_STATUS_FILE"
    fi
    
    # Check if rotation is overdue
    if command -v jq &> /dev/null; then
        local last_rotation=$(jq -r '.last_rotation_time // 0' "$ROTATION_STATUS_FILE" 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        local hours_since=$(((current_time - last_rotation) / 3600))
        
        if [[ $hours_since -gt 25 ]]; then
            echo
            echo "⚠️  WARNING: Last rotation was ${hours_since} hours ago (may be overdue)"
        fi
    fi
}

# Main
main() {
    display_status
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

