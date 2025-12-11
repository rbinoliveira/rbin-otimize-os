#!/usr/bin/env bash

# Log Rotation Library
# Version: 1.0.0
# Description: Provides log rotation functionality with compression and retention

# Source guard
if [[ -n ${LOG_ROTATE_SH_LOADED:-} ]]; then
    return 0
fi
readonly LOG_ROTATE_SH_LOADED=1

# Default configuration
readonly DEFAULT_LOG_MAX_SIZE_MB=10
readonly DEFAULT_LOG_RETENTION_DAYS=30
readonly DEFAULT_MAX_ROTATED_LOGS=5

# Rotate log file if it exceeds size threshold
rotate_logs() {
    local log_file="${1:-}"
    local max_size_mb="${2:-$DEFAULT_LOG_MAX_SIZE_MB}"
    local retention_days="${3:-$DEFAULT_LOG_RETENTION_DAYS}"
    local max_rotated="${4:-$DEFAULT_MAX_ROTATED_LOGS}"

    if [[ -z "$log_file" ]] || [[ ! -f "$log_file" ]]; then
        return 0
    fi

    # Check file size in MB
    local file_size_mb=0
    if [[ "$(uname -s)" == "Darwin" ]]; then
        file_size_mb=$(stat -f "%z" "$log_file" 2>/dev/null | awk '{print int($1/1024/1024)}' || echo "0")
    else
        file_size_mb=$(stat -c "%s" "$log_file" 2>/dev/null | awk '{print int($1/1024/1024)}' || echo "0")
    fi

    # Rotate if file exceeds threshold
    if [[ $file_size_mb -ge $max_size_mb ]]; then
        local log_dir=$(dirname "$log_file")
        local log_base=$(basename "$log_file")

        # Find highest rotation number
        local max_rotation=0
        for rotated in "$log_dir"/"${log_base}".*.gz; do
            if [[ -f "$rotated" ]]; then
                local num=$(echo "$rotated" | sed -n 's/.*\.\([0-9]\+\)\.gz$/\1/p')
                if [[ -n "$num" ]] && [[ $num -gt $max_rotation ]]; then
                    max_rotation=$num
                fi
            fi
        done

        # Rotate existing files
        for ((i=$max_rotation; i>=1; i--)); do
            local old_file="${log_file}.${i}.gz"
            local new_file="${log_file}.$((i+1)).gz"
            if [[ -f "$old_file" ]]; then
                mv "$old_file" "$new_file" 2>/dev/null || true
            fi
        done

        # Compress current log
        if gzip -c "$log_file" > "${log_file}.1.gz" 2>/dev/null; then
            > "$log_file"  # Clear original file
            echo "Log rotated: ${log_file} -> ${log_file}.1.gz"
        fi
    fi

    # Clean up old rotated logs
    cleanup_old_logs "$log_file" "$retention_days" "$max_rotated"
}

# Clean up old log files based on retention policy
cleanup_old_logs() {
    local log_file="${1:-}"
    local retention_days="${2:-$DEFAULT_LOG_RETENTION_DAYS}"
    local max_rotated="${3:-$DEFAULT_MAX_ROTATED_LOGS}"

    if [[ -z "$log_file" ]]; then
        return 0
    fi

    local log_dir=$(dirname "$log_file")
    local log_base=$(basename "$log_file")

    # Delete logs older than retention period
    if [[ "$(uname -s)" == "Darwin" ]]; then
        find "$log_dir" -name "${log_base}.*.gz" -type f -mtime +${retention_days} -delete 2>/dev/null || true
    else
        find "$log_dir" -name "${log_base}.*.gz" -type f -mtime +${retention_days} -delete 2>/dev/null || true
    fi

    # Keep only last N rotated logs
    local rotated_count=$(find "$log_dir" -name "${log_base}.*.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ $rotated_count -gt $max_rotated ]]; then
        find "$log_dir" -name "${log_base}.*.gz" -type f -printf '%T@ %p\n' 2>/dev/null | \
            sort -rn | tail -n +$((max_rotated + 1)) | cut -d' ' -f2- | xargs rm -f 2>/dev/null || \
        find "$log_dir" -name "${log_base}.*.gz" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | \
            sort -rn | tail -n +$((max_rotated + 1)) | cut -d' ' -f2- | xargs rm -f 2>/dev/null || true
    fi
}

# Rotate all logs in a directory
rotate_all_logs() {
    local log_dir="${1:-${HOME}/.os-optimize/logs}"
    local max_size_mb="${2:-$DEFAULT_LOG_MAX_SIZE_MB}"
    local retention_days="${3:-$DEFAULT_LOG_RETENTION_DAYS}"

    if [[ ! -d "$log_dir" ]]; then
        return 0
    fi

    # Find all .log files (not already rotated)
    while IFS= read -r log_file; do
        if [[ -f "$log_file" ]] && [[ ! "$log_file" =~ \.(gz|bz2)$ ]]; then
            rotate_logs "$log_file" "$max_size_mb" "$retention_days"
        fi
    done < <(find "$log_dir" -name "*.log" -type f 2>/dev/null)
}
