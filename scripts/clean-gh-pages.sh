#!/bin/bash

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="clean-gh-pages"

# Source logging utilities
if [[ -f "$SCRIPT_DIR/logging-utils.sh" ]]; then
    source "$SCRIPT_DIR/logging-utils.sh"
fi

if command -v log_info &> /dev/null; then
  log_info "Starting gh-pages branch cleanup"
  start_span "clean_gh_pages"
  increment_counter "gh_pages_cleanups"
else
  echo "Starting gh-pages branch cleanup..."
fi

REMOVE_PATHS_FILE="/tmp/remove-paths.txt"
> "$REMOVE_PATHS_FILE"

dirs_with_visible_files=$(git ls-tree -r origin/gh-pages:pr-preview --name-only 2>/dev/null | \
    grep -v '/\.' | \
    cut -d/ -f1 | \
    sort -u || true)

all_dirs=$(git ls-tree -d origin/gh-pages:pr-preview --name-only 2>/dev/null || true)

if [ -z "$all_dirs" ]; then
    if command -v log_info &> /dev/null; then
      log_info "No directories found in pr-preview or pr-preview does not exist"
      end_span
    else
      echo "No directories found in pr-preview or pr-preview does not exist"
    fi
    rm "$REMOVE_PATHS_FILE"
    exit 0
fi

while IFS= read -r dir; do
    if [ -n "$dir" ]; then
        if ! echo "$dirs_with_visible_files" | grep -q "^${dir}$"; then
            dir_path="pr-preview/$dir"
            if command -v log_info &> /dev/null; then
              log_info "Found directory to remove" "path=$dir_path"
              increment_counter "directories_to_remove"
            else
              echo "Found directory to remove: $dir_path"
            fi
            echo "$dir_path" >> "$REMOVE_PATHS_FILE"
        fi
    fi
done <<< "$all_dirs"

if [ ! -s "$REMOVE_PATHS_FILE" ]; then
    if command -v log_info &> /dev/null; then
      log_info "No empty or hidden-file-only directories found. Nothing to clean up."
      record_metric "directories_removed" "0"
      end_span
    else
      echo "No empty or hidden-file-only directories found. Nothing to clean up."
    fi
    rm "$REMOVE_PATHS_FILE"
    exit 0
fi

if command -v log_info &> /dev/null; then
  log_info "Running git-filter-repo to remove directories"
  start_span "git_filter_repo"
fi

if uvx git-filter-repo@2.47.0 --paths-from-file "$REMOVE_PATHS_FILE" --invert-paths --refs origin/gh-pages; then
  if command -v log_info &> /dev/null; then
    log_info "Successfully cleaned gh-pages branch"
    record_metric "cleanup_success" "1"
    end_span
    end_span
  fi
else
  if command -v log_error &> /dev/null; then
    log_error "Failed to clean gh-pages branch"
    record_metric "cleanup_success" "0"
    end_span
    end_span
  fi
  exit 1
fi
