#!/usr/bin/env bash

# Disk Analysis Library
# Version: 1.0.0
# Description: Functions for analyzing disk usage and categorizing files
# Usage: source lib/disk_analysis.sh

# Source guard to prevent double-loading
if [[ -n "${DISK_ANALYSIS_SH_LOADED:-}" ]]; then
    return 0
fi

readonly DISK_ANALYSIS_SH_LOADED=1
readonly DISK_ANALYSIS_VERSION="1.0.0"

HIGHLIGHT_THRESHOLD="${HIGHLIGHT_THRESHOLD:-100}"
ANALYSIS_TIMEOUT="${ANALYSIS_TIMEOUT:-300}"

# Helper function to get the correct HOME directory
# Uses HOME_OVERRIDE if set (for multi-user cleanup), otherwise uses $HOME
get_user_home() {
    echo "${HOME_OVERRIDE:-$HOME}"
}

# ============ Library Dependencies ============
if [[ -z "${COMMON_SH_LOADED:-}" ]]; then
    # Try to source from same directory as this script
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${script_dir}/common.sh" ]]; then
        source "${script_dir}/common.sh"
    else
        echo "Error: common.sh not found. Please source it before disk_analysis.sh" >&2
        return 1
    fi
fi

# Ensure cleanup mode functions are available (fallback if not loaded)
if ! command -v is_safe_mode >/dev/null 2>&1; then
    is_safe_mode() {
        [[ "${CLEANUP_MODE:-safe}" == "safe" ]]
    }
    is_moderate_mode() {
        [[ "${CLEANUP_MODE:-safe}" == "moderate" ]]
    }
    is_aggressive_mode() {
        [[ "${CLEANUP_MODE:-safe}" == "aggressive" ]]
    }
fi

# ============ Disk Analysis Functions ============

format_bytes() {
    local bytes="$1"
    local precision="${2:-2}"

    if [[ -z "$bytes" ]] || [[ "$bytes" -lt 0 ]]; then
        echo "0 B"
        return
    fi

    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit_index=0
    local size=$(echo "$bytes" | awk '{printf "%.2f", $1}')

    while [[ $(echo "$size >= 1024" | bc 2>/dev/null || echo "0") -eq 1 ]] && [[ $unit_index -lt $((${#units[@]} - 1)) ]]; do
        size=$(echo "scale=$precision; $size / 1024" | bc 2>/dev/null || echo "0")
        unit_index=$((unit_index + 1))
    done

    # Fallback to awk if bc not available
    if ! command -v bc >/dev/null 2>&1; then
        local size_float="$bytes"
        unit_index=0
        while [[ $size_float -ge 1024 ]] && [[ $unit_index -lt $((${#units[@]} - 1)) ]]; do
            size_float=$((size_float / 1024))
            unit_index=$((unit_index + 1))
        done
        echo "${size_float} ${units[$unit_index]}"
    else
        echo "${size} ${units[$unit_index]}"
    fi
}

get_disk_categories() {
    # Android/iOS categories are intentionally excluded to preserve dev environments:
    #   xcode, xcode_archives, xcode_device_support, ios_simulators,
    #   cocoapods_cache, android_studio, gradle,
    #   xcode_app, xcode_developer_full, xcode_simulator_full, xcode_command_line_tools,
    #   android_studio_app, android_library, android_application_support, gradle_full
    local base_categories="caches logs temp browser_trash react_native node_modules docker volumes build_artifacts orphaned_apps npm_cache expo_cache vscode_cache nvm_cache yarn_cache pip_cache gem_cache homebrew_cache flutter_cache swiftpm_cache xcode_sim_logs carthage_cache ruby_bundler_cache turborepo_cache jest_cache playwright_cache cypress_cache pnpm_store bun_cache android_project_builds ios_project_builds android_avd android_sdk_old ios_simulator_devices"

    # Add moderate mode categories
    local moderate_categories="application_support_google application_support_cursor application_support_wallpaper containers_cleanup nuget_cache dotnet_cache homebrew_cleanup"

    # Add aggressive mode categories (Android/iOS intentionally excluded)
    local aggressive_categories="yarn_full nvm_full docker_full large_directories dev_directory"

    if is_macos; then
        if is_aggressive_mode; then
            echo "${base_categories} ${moderate_categories} ${aggressive_categories}"
        elif is_moderate_mode; then
            echo "${base_categories} ${moderate_categories}"
        else
            # Safe mode - only base categories
            echo "$base_categories"
        fi
    elif is_linux; then
        echo "caches logs temp browser_trash apt yum pacman react_native node_modules docker volumes build_artifacts snap orphaned_apps npm_cache expo_cache vscode_cache nvm_cache yarn_cache pip_cache gem_cache"
    else
        echo "caches logs temp"
    fi
}

analyze_disk_usage() {
    local path="${1:-}"
    local category="${2:-unknown}"
    local max_depth="${3:-3}"

    if [[ -z "$path" ]] || [[ ! -e "$path" ]]; then
        log_warn "Path does not exist: $path"
        return 1
    fi

    local total_size=0
    local file_count=0
    local dir_count=0

    if command -v du >/dev/null 2>&1; then
        # Calculate total size (protected dirs included in size but excluded from counts)
        local size_output=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]' || echo "0")
        # Ensure we have a valid number, default to 0 if empty or invalid
        if [[ -z "$size_output" ]] || ! [[ "$size_output" =~ ^[0-9]+$ ]]; then
            size_output="0"
        fi
        # Use awk for multiplication to handle large numbers safely
        total_size=$(awk "BEGIN {printf \"%.0f\", $size_output * 1024}" 2>/dev/null)
        # Fallback to bash arithmetic if awk fails or returns empty
        if [[ -z "$total_size" ]] || ! [[ "$total_size" =~ ^[0-9]+$ ]]; then
            if [[ "$size_output" =~ ^[0-9]+$ ]]; then
        total_size=$((size_output * 1024))
            else
                total_size=0
            fi
        fi

        # Count files and directories excluding protected ones
        file_count=$(find "$path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth "$max_depth" -type f -print 2>/dev/null | wc -l | tr -d ' ')
        dir_count=$(find "$path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth "$max_depth" -type d -print 2>/dev/null | wc -l | tr -d ' ')
    else
        log_warn "du command not found, using find as fallback"
        local sizes=$(find "$path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth "$max_depth" -type f -exec stat -f%z {} \; 2>/dev/null || find "$path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth "$max_depth" -type f -exec stat -c%s {} \; 2>/dev/null)
        for size in $sizes; do
            total_size=$((total_size + size))
        done
        file_count=$(find "$path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth "$max_depth" -type f -print 2>/dev/null | wc -l | tr -d ' ')
        dir_count=$(find "$path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth "$max_depth" -type d -print 2>/dev/null | wc -l | tr -d ' ')
    fi

    local size_formatted=$(format_bytes "$total_size")
    local size_mb=$((total_size / 1024 / 1024))
    echo "${category}|${path}|${total_size}|${size_formatted}|${size_mb}|${file_count}|${dir_count}"
}

get_category_path() {
    local category="$1"

    case "$category" in
        caches)
            if is_macos; then
                echo "$(get_user_home)/Library/Caches"
            else
                echo "$(get_user_home)/.cache"
            fi
            ;;
        logs)
            if is_macos; then
                echo "$(get_user_home)/Library/Logs"
            else
                echo "/var/log"
            fi
            ;;
        # downloads removed - too dangerous, may contain important user files
        # downloads)
        #     echo "${HOME}/Downloads"
        #     ;;
        temp)
            if is_macos; then
                echo "/tmp"
            else
                echo "/tmp"
            fi
            ;;
        browser_trash)
            if is_macos; then
                echo "$(get_user_home)/.Trash"
            else
                echo "$(get_user_home)/.local/share/Trash"
            fi
            ;;
        xcode)
            if is_macos; then
                echo "$(get_user_home)/Library/Developer/Xcode/DerivedData"
            else
                echo ""
            fi
            ;;
        xcode_archives)
            if is_macos; then
                echo "$(get_user_home)/Library/Developer/Xcode/Archives"
            else
                echo ""
            fi
            ;;
        xcode_device_support)
            if is_macos; then
                echo "$(get_user_home)/Library/Developer/Xcode/iOS DeviceSupport"
            else
                echo ""
            fi
            ;;
        ios_simulators)
            if is_macos; then
                echo "$(get_user_home)/Library/Developer/CoreSimulator/Caches"
            else
                echo ""
            fi
            ;;
        android_studio)
            echo "$(get_user_home)/.android"
            ;;
        gradle)
            echo "$(get_user_home)/.gradle/caches"
            ;;
        react_native)
            # React Native has multiple cache locations
            echo ""
            ;;
        node_modules)
            echo "$(get_user_home)/.node_modules"
            ;;
        docker)
            if is_macos; then
                echo "$(get_user_home)/Library/Containers/com.docker.docker/Data/vms"
            else
                echo "/var/lib/docker"
            fi
            ;;
        volumes)
            echo ""
            ;;
        build_artifacts)
            echo ""
            ;;
        orphaned_apps)
            if is_macos; then
                echo "$(get_user_home)/Library/Application Support"
            else
                echo "$(get_user_home)/.config"
            fi
            ;;
        apt)
            if is_linux; then
                echo "/var/cache/apt"
            else
                echo ""
            fi
            ;;
        yum)
            if is_linux; then
                echo "/var/cache/yum"
            else
                echo ""
            fi
            ;;
        pacman)
            if is_linux; then
                echo "/var/cache/pacman/pkg"
            else
                echo ""
            fi
            ;;
        snap)
            if is_linux; then
                echo "/var/lib/snapd/cache"
            else
                echo ""
            fi
            ;;
        npm_cache)
            echo "$(get_user_home)/.npm"
            ;;
        expo_cache)
            echo "$(get_user_home)/.expo"
            ;;
        vscode_cache)
            if is_macos; then
                echo "$(get_user_home)/Library/Application Support/Code/Cache"
            else
                echo "$(get_user_home)/.config/Code/Cache"
            fi
            ;;
        nvm_cache)
            echo "$(get_user_home)/.nvm/.cache"
            ;;
        cocoapods_cache)
            if is_macos; then
                echo "$(get_user_home)/.cocoapods"
            else
                echo ""
            fi
            ;;
        yarn_cache)
            echo "$(get_user_home)/.yarn/cache"
            ;;
        pip_cache)
            if is_macos; then
                echo "$(get_user_home)/Library/Caches/pip"
            else
                echo "$(get_user_home)/.cache/pip"
            fi
            ;;
        gem_cache)
            echo "$(get_user_home)/.gem/cache"
            ;;
        homebrew_cache)
            if is_macos; then
                if command -v brew >/dev/null 2>&1; then
                    echo "$(brew --cache)"
                else
                    echo "$(get_user_home)/Library/Caches/Homebrew"
                fi
            else
                echo ""
            fi
            ;;
        # Xcode aggressive categories
        xcode_app)
            if is_macos; then
                echo "/Applications/Xcode.app"
            else
                echo ""
            fi
            ;;
        xcode_developer_full)
            if is_macos; then
                echo "$(get_user_home)/Library/Developer/Xcode"
            else
                echo ""
            fi
            ;;
        xcode_simulator_full)
            if is_macos; then
                echo "$(get_user_home)/Library/Developer/CoreSimulator"
            else
                echo ""
            fi
            ;;
        xcode_command_line_tools)
            if is_macos; then
                echo "/Library/Developer/CommandLineTools"
            else
                echo ""
            fi
            ;;
        # Android Studio aggressive categories
        android_studio_app)
            if is_macos; then
                echo "/Applications/Android Studio.app"
            else
                echo ""
            fi
            ;;
        android_library)
            echo "$(get_user_home)/Library/Android"
            ;;
        android_application_support)
            if is_macos; then
                echo "$(get_user_home)/Library/Application Support/Google/AndroidStudio*"
            else
                echo ""
            fi
            ;;
        # Application Support heavy
        application_support_google)
            if is_macos; then
                echo "$(get_user_home)/Library/Application Support/Google"
            else
                echo ""
            fi
            ;;
        application_support_cursor)
            if is_macos; then
                echo "$(get_user_home)/Library/Application Support/Cursor"
            else
                echo ""
            fi
            ;;
        application_support_wallpaper)
            if is_macos; then
                echo "$(get_user_home)/Library/Application Support/com.apple.wallpaper"
            else
                echo ""
            fi
            ;;
        # Containers cleanup
        containers_cleanup)
            if is_macos; then
                echo "$(get_user_home)/Library/Containers"
            else
                echo ""
            fi
            ;;
        # .NET categories
        nuget_cache)
            echo "$(get_user_home)/.nuget"
            ;;
        dotnet_cache)
            echo "$(get_user_home)/.dotnet"
            ;;
        # Homebrew cleanup
        homebrew_cleanup)
            if is_macos; then
                echo "BREW_COMMAND"
            else
                echo ""
            fi
            ;;
        # Aggressive language environments
        gradle_full)
            echo "$(get_user_home)/.gradle"
            ;;
        yarn_full)
            echo "$(get_user_home)/.yarn"
            ;;
        nvm_full)
            echo "$(get_user_home)/.nvm"
            ;;
        docker_full)
            echo "$(get_user_home)/.docker"
            ;;
        # Large directories and dev
        large_directories)
            echo "SCAN_MODE"
            ;;
        dev_directory)
            echo "$(get_user_home)/dev"
            ;;
        flutter_cache) echo "$(get_user_home)/.pub-cache" ;;
        swiftpm_cache) is_macos && echo "$(get_user_home)/Library/Caches/org.swift.swiftpm" || echo "" ;;
        xcode_sim_logs) echo "" ;;  # multiple paths, handled in scan
        carthage_cache) is_macos && echo "$(get_user_home)/Library/Caches/org.carthage.CarthageKit" || echo "" ;;
        ruby_bundler_cache) echo "$(get_user_home)/.bundle/cache" ;;
        turborepo_cache) echo "$(get_user_home)/.turbo" ;;
        jest_cache) echo "" ;;  # /tmp/jest-* wildcard, handled in scan
        playwright_cache) is_macos && echo "$(get_user_home)/Library/Caches/ms-playwright" || echo "$(get_user_home)/.cache/ms-playwright" ;;
        cypress_cache) echo "$(get_user_home)/.cache/Cypress" ;;
        pnpm_store) echo "$(get_user_home)/.pnpm-store" ;;
        bun_cache) echo "$(get_user_home)/.bun/install/cache" ;;
        android_project_builds) echo "" ;;  # scan-based
        ios_project_builds) echo "" ;;      # scan-based
        android_avd) echo "$(get_user_home)/.android/avd" ;;
        android_sdk_old) echo "$(get_user_home)/Library/Android/sdk/platforms" ;;
        ios_simulator_devices) is_macos && echo "$(get_user_home)/Library/Developer/CoreSimulator/Devices" || echo "" ;;
        *)
            echo ""
            ;;
    esac
}

# Analyze all disk categories
analyze_all_categories() {
    local categories=$(get_disk_categories)
    local results=()

    log_info "Starting disk usage analysis..."

    for category in $categories; do
        local path=$(get_category_path "$category")

        if [[ -z "$path" ]] || [[ ! -e "$path" ]]; then
            log_debug "Skipping category $category (path not found: $path)"
            continue
        fi

        log_info "Analyzing category: $category ($path)"
        local result=$(analyze_disk_usage "$path" "$category")
        if [[ -n "$result" ]]; then
            results+=("$result")
        fi
    done

    printf '%s\n' "${results[@]}"
}

# ============ Function Exports ============

export -f format_bytes
export -f get_disk_categories
export -f analyze_disk_usage
export -f get_category_path
export -f analyze_all_categories
