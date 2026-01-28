#!/usr/bin/env bash

# Cleanup Preview Library
# Version: 1.0.0
# Description: Functions for previewing and managing cleanup operations
# Usage: source lib/cleanup_preview.sh

# Source guard to prevent double-loading
if [[ -n "${CLEANUP_PREVIEW_SH_LOADED:-}" ]]; then
    return 0
fi

readonly CLEANUP_PREVIEW_SH_LOADED=1
readonly CLEANUP_PREVIEW_VERSION="1.0.0"

# Source common.sh for logging and platform detection
if [[ -z "${COMMON_SH_LOADED:-}" ]]; then
    # Try to source from same directory as this script
    _cleanup_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_cleanup_script_dir}/common.sh" ]]; then
        source "${_cleanup_script_dir}/common.sh"
    else
        echo "Error: common.sh not found. Please source it before cleanup_preview.sh" >&2
        return 1
    fi
fi

# Source disk_analysis.sh if available
if [[ -z "${DISK_ANALYSIS_SH_LOADED:-}" ]]; then
    _cleanup_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_cleanup_script_dir}/disk_analysis.sh" ]]; then
        source "${_cleanup_script_dir}/disk_analysis.sh"
    fi
fi

FORCE_MODE="${FORCE_MODE:-false}"

# ============ Cleanup Category Functions ============

get_cleanup_categories() {
    if is_macos; then
        # Removed 'downloads' - too dangerous, may contain important user files
        echo "caches logs temp browser_trash xcode xcode_archives xcode_device_support ios_simulators android_studio gradle react_native node_modules docker volumes build_artifacts orphaned_apps"
    elif is_linux; then
        echo "caches logs temp browser_trash apt yum pacman android_studio gradle react_native node_modules docker volumes build_artifacts snap orphaned_apps"
    else
        echo "caches logs temp"
    fi
}

# Find orphaned applications (apps deleted but configs remain)
find_orphaned_apps() {
    local orphaned_apps=()

    if ! is_macos; then
        # Linux: check ~/.config and ~/.local/share
        local config_dir="${HOME}/.config"

        if [[ -d "$config_dir" ]]; then
            while IFS= read -r app_dir; do
                [[ -z "$app_dir" ]] && continue
                local app_name=$(basename "$app_dir")
                # Check if app binary exists in common locations
                if ! command -v "$app_name" >/dev/null 2>&1 && \
                   [[ ! -f "/usr/bin/$app_name" ]] && \
                   [[ ! -f "/usr/local/bin/$app_name" ]] && \
                   [[ ! -d "/opt/$app_name" ]]; then
                    orphaned_apps+=("$app_dir")
                fi
            done < <(find "$config_dir" -maxdepth 1 -type d ! -path "$config_dir" 2>/dev/null)
        fi
    else
        # macOS: check Application Support for apps that no longer exist in /Applications
        local app_support="${HOME}/Library/Application Support"

        if [[ ! -d "$app_support" ]]; then
            return 0
        fi

        # Build list of installed apps (by bundle ID and name)
        local installed_bundle_ids=()
        local installed_app_names=()

        # Scan /Applications for installed apps
        while IFS= read -r app_path; do
            [[ -z "$app_path" ]] || [[ ! -d "$app_path" ]] && continue

            # Get bundle ID
            if [[ -f "${app_path}/Contents/Info.plist" ]]; then
                local bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${app_path}/Contents/Info.plist" 2>/dev/null)
                if [[ -n "$bundle_id" ]]; then
                    installed_bundle_ids+=("$bundle_id")
                fi
            fi

            # Get app name (without .app extension)
            local app_name=$(basename "$app_path" .app)
            if [[ -n "$app_name" ]]; then
                installed_app_names+=("$app_name")
            fi
        done < <(find /Applications -maxdepth 2 -name "*.app" -type d 2>/dev/null)

        # Check Application Support directories
        while IFS= read -r app_dir; do
            [[ -z "$app_dir" ]] || [[ ! -d "$app_dir" ]] && continue
            local app_name=$(basename "$app_dir")

            # Skip system apps and known safe apps (always installed)
            if [[ "$app_name" == "com.apple"* ]] || \
               [[ "$app_name" == "Apple"* ]] || \
               [[ "$app_name" == "Microsoft"* ]] || \
               [[ "$app_name" == "Google"* ]] || \
               [[ "$app_name" == "Adobe"* ]]; then
                continue
            fi

            # Check if it's a bundle ID format
            local is_bundle_id=false
            if [[ "$app_name" =~ ^[a-z]+\.[a-z]+\.[a-z]+ ]]; then
                is_bundle_id=true
            fi

            # Check if app is installed
            local app_found=false

            if [[ "$is_bundle_id" == "true" ]]; then
                # Check by bundle ID (exact match or prefix match)
                for installed_id in "${installed_bundle_ids[@]}"; do
                    # Exact match
                    if [[ "$app_name" == "$installed_id" ]]; then
                        app_found=true
                        break
                    fi
                    # Prefix match (e.g., com.todesktop.xxx matches com.todesktop.230313mzl4w4u92)
                    if [[ "$app_name" == "$installed_id"* ]] || [[ "$installed_id" == "$app_name"* ]]; then
                        app_found=true
                        break
                    fi
                done
            fi

            if [[ "$app_found" == "false" ]]; then
                # Check by app name (try to extract app name from bundle ID or directory name)
                if [[ "$is_bundle_id" == "true" ]]; then
                    # For bundle IDs, check if the directory name matches an installed app
                    # Example: "Cursor" directory should match "Cursor.app"
                    # Extract possible app name from bundle ID parts
                    local bundle_parts=$(echo "$app_name" | tr '.' ' ')
                    for part in $bundle_parts; do
                        # Skip common prefixes and numeric IDs
                        [[ "$part" == "com" ]] && continue
                        [[ "$part" =~ ^[0-9]+$ ]] && continue
                        [[ ${#part} -lt 3 ]] && continue

                        # Try to match with installed app names (case-insensitive)
                        local part_lower=$(echo "$part" | tr '[:upper:]' '[:lower:]')
                        for installed_name in "${installed_app_names[@]}"; do
                            local installed_lower=$(echo "$installed_name" | tr '[:upper:]' '[:lower:]')
                            if [[ "$installed_lower" == "$part_lower" ]] || \
                               [[ "$installed_lower" == *"$part_lower"* ]] || \
                               [[ "$part_lower" == *"$installed_lower"* ]]; then
                                app_found=true
                                break 2
                            fi
                        done
                    done
                else
                    # Direct name match (case-insensitive)
                    local app_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                    for installed_name in "${installed_app_names[@]}"; do
                        local installed_lower=$(echo "$installed_name" | tr '[:upper:]' '[:lower:]')
                        if [[ "$installed_lower" == "$app_name_lower" ]] || \
                           [[ "$installed_lower" == *"$app_name_lower"* ]] || \
                           [[ "$app_name_lower" == *"$installed_lower"* ]]; then
                            app_found=true
                            break
                        fi
                    done
                fi
            fi

            # If app not found, it's orphaned
            if [[ "$app_found" == "false" ]]; then
                orphaned_apps+=("$app_dir")
            fi
        done < <(find "$app_support" -maxdepth 1 -type d ! -path "$app_support" 2>/dev/null)
    fi

    printf '%s\n' "${orphaned_apps[@]}"
}

# Check if file should be excluded from cleanup
# Only protects critical system files, allows dev files to be cleaned
should_exclude_file() {
    local file="$1"
    [[ -z "$file" ]] && return 0

    local basename_file=$(basename "$file" 2>/dev/null || echo "$file")
    local dirname_file=$(dirname "$file" 2>/dev/null || echo "")

    # Protect critical development tool directories (never delete these)
    # User wants to clean dev files, so we allow node_modules, build files, etc. to be deleted
    local protected_dirs=(
        ".git"
        ".claude"
        ".cursor"
        ".task-flow"
    )
    
    for protected_dir in "${protected_dirs[@]}"; do
        if [[ "$file" == *"/${protected_dir}/"* ]] || \
           [[ "$file" == *"/${protected_dir}" ]] || \
           [[ "$basename_file" == "$protected_dir" ]] || \
           [[ "$dirname_file" == *"/${protected_dir}"* ]] || \
           [[ "$dirname_file" == *"/${protected_dir}/"* ]]; then
            return 0  # Exclude - protect this directory
        fi
    done

    # Protect system critical files only
    if [[ "$basename_file" == ".DS_Store" ]] && [[ "$file" != *"/Library/Caches/"* ]]; then
        # Allow .DS_Store in caches to be cleaned, but protect elsewhere
        return 1  # Don't exclude
    fi

    return 1  # Don't exclude - allow dev files to be cleaned
}

# Scan for node_modules in common project directories
# Optimized to avoid hanging on large node_modules - uses sampling approach
scan_node_modules() {
    local min_age_days="${1:-0}"
    local files=()
    local search_paths=(
        "${HOME}/dev"
        "${HOME}/projects"
        "${HOME}/workspace"
        "${HOME}/code"
        "${HOME}/Documents"
        "${HOME}/Desktop"
    )

    log_info "Scanning for node_modules directories (optimized scan)..."

    for base_path in "${search_paths[@]}"; do
        [[ ! -d "$base_path" ]] && continue

        # Find node_modules directories with maxdepth to avoid deep recursion
        # Limit to first 20 node_modules to prevent hanging
        local node_modules_dirs=()
        local count=0
        while IFS= read -r dir && [[ $count -lt 20 ]]; do
            [[ -z "$dir" ]] && continue
            node_modules_dirs+=("$dir")
            count=$((count + 1))
        done < <(find "$base_path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth 4 -type d -name "node_modules" -print 2>/dev/null | head -20) || true

        # Process each node_modules directory with strict limits
        # Check if array has elements before iterating (prevent unbound variable error with set -u)
        local dir_count=${#node_modules_dirs[@]:-0}
        if [[ $dir_count -gt 0 ]]; then
            # Use safe iteration that works with set -u
            local idx=0
            while [[ $idx -lt $dir_count ]]; do
                local dir="${node_modules_dirs[$idx]}"
            [[ ! -d "$dir" ]] && continue

            # For preview, use a very limited sample (first 100 files only)
            # This is just for size estimation, not for actual deletion list
            if [[ $min_age_days -gt 0 ]]; then
                # For age filter, limit severely to prevent hanging
                while IFS= read -r file && [[ ${#files[@]} -lt 500 ]]; do
                    [[ -n "$file" ]] && files+=("$file")
                done < <(find "$dir" -maxdepth 2 -type f -mtime +${min_age_days} 2>/dev/null | head -500)
            else
                # For preview, use minimal sampling (just 50 files per node_modules)
                while IFS= read -r file && [[ ${#files[@]} -lt 50 ]]; do
                    [[ -n "$file" ]] && files+=("$file")
                done < <(find "$dir" -maxdepth 2 -type f 2>/dev/null | head -50)
            fi

                # Break early if we've collected enough samples
                [[ ${#files[@]} -ge 1000 ]] && break
                idx=$((idx + 1))
            done
        fi

        # Break early if we've collected enough samples
        [[ ${#files[@]} -ge 1000 ]] && break
    done

    printf '%s\n' "${files[@]}"
}

# Scan for build artifacts in common project directories
# Optimized to avoid hanging on large build directories
scan_build_artifacts() {
    local min_age_days="${1:-0}"
    local files=()
    local search_paths=(
        "${HOME}/dev"
        "${HOME}/projects"
        "${HOME}/workspace"
        "${HOME}/code"
    )

    local build_patterns=(
        "dist"
        "build"
        "target"
        ".next"
        ".turbo"
        ".parcel-cache"
        "out"
        ".output"
        ".nuxt"
        ".vuepress/dist"
        ".cache"
        "coverage"
        ".nyc_output"
    )

    log_info "Scanning for build artifacts (optimized scan)..."

    for base_path in "${search_paths[@]}"; do
        [[ ! -d "$base_path" ]] && continue

        # Limit search depth and number of results to prevent hanging
        for pattern in "${build_patterns[@]}"; do
            if [[ $min_age_days -gt 0 ]]; then
                # For age filter, limit results severely
                while IFS= read -r file && [[ ${#files[@]} -lt 1000 ]]; do
                    [[ -n "$file" ]] && files+=("$file")
                done < <(find "$base_path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth 5 -type f -path "*/${pattern}/*" -mtime +${min_age_days} -print 2>/dev/null | head -1000)
            else
                # For preview, use minimal sampling (first 100 files per pattern)
                while IFS= read -r file && [[ ${#files[@]} -lt 500 ]]; do
                    [[ -n "$file" ]] && files+=("$file")
                done < <(find "$base_path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth 5 -type f -path "*/${pattern}/*" -print 2>/dev/null | head -100)
            fi

            # Break early if we've collected enough samples
            [[ ${#files[@]} -ge 2000 ]] && break
        done

        # Break early if we've collected enough samples
        [[ ${#files[@]} -ge 2000 ]] && break
    done

    printf '%s\n' "${files[@]}"
}

scan_cleanup_category() {
    local category="$1"
    local min_age_days="${2:-0}"
    local path=""

    # Handle special categories that don't have a single path
    case "$category" in
        react_native)
            # React Native has multiple cache locations
            local total_size=0
            local file_count=0
            local cache_paths=(
                "${HOME}/.rncache"
                "${HOME}/Library/Caches/Metro"
                "${HOME}/Library/Caches/com.facebook.ReactNativeBuild"
                "/tmp/metro-*"
                "/tmp/haste-map-*"
                "/tmp/react-*"
            )

            for cache_path in "${cache_paths[@]}"; do
                # Handle wildcards
                if [[ "$cache_path" == *"*"* ]]; then
                    while IFS= read -r dir; do
                        [[ -z "$dir" ]] || [[ ! -e "$dir" ]] && continue
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                                local estimated_files=$((dir_size * 10))
                                file_count=$((file_count + estimated_files))
                            fi
                        fi
                    done < <(find "$(dirname "$cache_path")" -maxdepth 1 -name "$(basename "$cache_path")" 2>/dev/null)
                else
                    if [[ -e "$cache_path" ]]; then
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                                local estimated_files=$((dir_size * 10))
                                file_count=$((file_count + estimated_files))
                            fi
                        fi
                    fi
                fi
            done

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|React Native caches|${file_count}|${total_size}"
            return 0
            ;;
        android_studio)
            # Android Studio caches
            local total_size=0
            local file_count=0
            local cache_paths=(
                "${HOME}/.android/cache"
                "${HOME}/.android/build-cache"
                "${HOME}/Library/Caches/AndroidStudio*"
            )

            for cache_path in "${cache_paths[@]}"; do
                if [[ "$cache_path" == *"*"* ]]; then
                    while IFS= read -r dir; do
                        [[ -z "$dir" ]] || [[ ! -e "$dir" ]] && continue
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                                local estimated_files=$((dir_size * 20))
                                file_count=$((file_count + estimated_files))
                            fi
                        fi
                    done < <(find "$(dirname "$cache_path")" -maxdepth 1 -name "$(basename "$cache_path")" -type d 2>/dev/null)
                else
                    if [[ -e "$cache_path" ]]; then
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                                local estimated_files=$((dir_size * 20))
                                file_count=$((file_count + estimated_files))
                            fi
                        fi
                    fi
                fi
            done

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|Android Studio caches|${file_count}|${total_size}"
            return 0
            ;;
        gradle)
            # Gradle caches
            local cache_path="${HOME}/.gradle/caches"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        ios_simulators)
            # iOS Simulator caches (macOS only)
            if ! is_macos; then
                return 0
            fi

            local total_size=0
            local file_count=0
            local cache_paths=(
                "${HOME}/Library/Developer/CoreSimulator/Caches"
                "${HOME}/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches"
            )

            for cache_path in "${cache_paths[@]}"; do
                if [[ "$cache_path" == *"*"* ]]; then
                    while IFS= read -r dir; do
                        [[ -z "$dir" ]] || [[ ! -e "$dir" ]] && continue
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                                local estimated_files=$((dir_size * 10))
                                file_count=$((file_count + estimated_files))
                            fi
                        fi
                    done < <(find "$(dirname "$(dirname "$cache_path")")" -path "$cache_path" -type d 2>/dev/null)
                else
                    if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                        local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                        if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + dir_size * 1024))
                            local estimated_files=$((dir_size * 10))
                            file_count=$((file_count + estimated_files))
                        fi
                    fi
                fi
            done

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|iOS Simulator caches|${file_count}|${total_size}"
            return 0
            ;;
        xcode_archives)
            # Xcode Archives (macOS only)
            if ! is_macos; then
                return 0
            fi

            local path="${HOME}/Library/Developer/Xcode/Archives"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + dir_size * 1024))
                    file_count=$((dir_size * 5))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        xcode_device_support)
            # Xcode Device Support (macOS only)
            if ! is_macos; then
                return 0
            fi

            local path="${HOME}/Library/Developer/Xcode/iOS DeviceSupport"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + dir_size * 1024))
                    file_count=$((dir_size * 5))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        node_modules)
            # Use optimized scanning - calculate size with du instead of listing all files
            local total_size=0
            local file_count=0
            local search_paths=("${HOME}/dev" "${HOME}/projects" "${HOME}/workspace" "${HOME}/code" "${HOME}/Documents" "${HOME}/Desktop")

            for base_path in "${search_paths[@]}"; do
                [[ ! -d "$base_path" ]] && continue

                # Find node_modules and calculate size with du (much faster than listing files)
                while IFS= read -r dir; do
                    [[ -z "$dir" ]] || [[ ! -d "$dir" ]] && continue

                    # Use du to get directory size (much faster)
                    if command -v du >/dev/null 2>&1; then
                        local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                        if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + dir_size * 1024))
                            # Estimate file count (rough: 1 file per 10KB average)
                            local estimated_files=$((dir_size * 100))
                            file_count=$((file_count + estimated_files))
                        fi
                    fi
                done < <(find "$base_path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth 4 -type d -name "node_modules" -print 2>/dev/null | head -20)
            done

            # Ensure minimum count
            [[ $file_count -eq 0 ]] && file_count=1

            echo "${category}|Multiple project directories|${file_count}|${total_size}"
            return 0
            ;;
        build_artifacts)
            # Use optimized scanning - calculate size with du instead of listing all files
            local total_size=0
            local file_count=0
            local search_paths=("${HOME}/dev" "${HOME}/projects" "${HOME}/workspace" "${HOME}/code")
            local build_patterns=("dist" "build" "target" ".next" ".turbo" ".parcel-cache" "out" ".output" ".nuxt" ".vuepress/dist" ".cache" "coverage" ".nyc_output")

            for base_path in "${search_paths[@]}"; do
                [[ ! -d "$base_path" ]] && continue

                # Find build artifact directories and calculate size with du (much faster)
                for pattern in "${build_patterns[@]}"; do
                    while IFS= read -r dir; do
                        [[ -z "$dir" ]] || [[ ! -d "$dir" ]] && continue

                        # Use du to get directory size (much faster)
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                                # Estimate file count (rough: 1 file per 50KB average for build artifacts)
                                local estimated_files=$((dir_size * 20))
                                file_count=$((file_count + estimated_files))
                            fi
                        fi
                    done < <(find "$base_path" -maxdepth 5 -type d -name "$pattern" 2>/dev/null | head -50)
                done
            done

            # Ensure minimum count
            [[ $file_count -eq 0 ]] && file_count=1

            echo "${category}|Multiple project directories|${file_count}|${total_size}"
            return 0
            ;;
        volumes)
            if ! command -v docker >/dev/null 2>&1; then
                return 0
            fi
            local volume_count=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
            echo "${category}|Docker volumes|${volume_count}|0"
            return 0
            ;;
        orphaned_apps)
            # Find orphaned app directories
            local orphaned_dirs=()
            while IFS= read -r dir; do
                [[ -n "$dir" ]] && orphaned_dirs+=("$dir")
            done < <(find_orphaned_apps)

            local dir_count=${#orphaned_dirs[@]}
            local total_size=0

            for dir in "${orphaned_dirs[@]}"; do
                if [[ -d "$dir" ]] && command -v du >/dev/null 2>&1; then
                    local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                    if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                        total_size=$((total_size + dir_size * 1024))
                    fi
                fi
            done

            echo "${category}|Application Support & Preferences|${dir_count}|${total_size}"
            return 0
            ;;
    esac

    if command -v get_category_path >/dev/null 2>&1; then
        path=$(get_category_path "$category")
    else
        case "$category" in
            caches)
                path=$(is_macos && echo "${HOME}/Library/Caches" || echo "${HOME}/.cache")
                ;;
            logs)
                path=$(is_macos && echo "${HOME}/Library/Logs" || echo "/var/log")
                ;;
            # downloads removed - too dangerous, may contain important user files
            # downloads)
            #     path="${HOME}/Downloads"
            #     ;;
            temp)
                path="/tmp"
                ;;
            browser_trash)
                path=$(is_macos && echo "${HOME}/.Trash" || echo "${HOME}/.local/share/Trash")
                ;;
            *)
                log_warn "Unknown category: $category"
                return 1
                ;;
        esac
    fi

    if [[ -z "$path" ]] || [[ ! -e "$path" ]]; then
        log_debug "Category $category: path not found ($path)"
        return 1
    fi

    log_info "Scanning category: $category ($path)"

    local files=()
    local total_size=0

    # Find files based on age filter
    if [[ $min_age_days -gt 0 ]]; then
        # Find files older than min_age_days
        local cutoff_date=$(date -v-${min_age_days}d 2>/dev/null || date -d "${min_age_days} days ago" 2>/dev/null)

        if is_macos; then
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                if ! should_exclude_file "$file"; then
                    files+=("$file")
                fi
            done < <(find "$path" -type f -mtime +${min_age_days} -print0 2>/dev/null | xargs -0)
        else
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                if ! should_exclude_file "$file"; then
                    files+=("$file")
                fi
            done < <(find "$path" -type f -mtime +${min_age_days} -print0 2>/dev/null | xargs -0)
        fi
    else
        # Find all files, but exclude important development files
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if ! should_exclude_file "$file"; then
                files+=("$file")
            fi
        done < <(find "$path" -type f -print0 2>/dev/null | xargs -0)
    fi

    # Calculate total size
    if [[ ${#files[@]} -gt 0 ]]; then
        for file in "${files[@]}"; do
            if [[ -f "$file" ]] && [[ ! -L "$file" ]]; then  # Skip symlinks
                local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
                # Ensure size is a valid number
                if [[ "$size" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + size))
                fi
            fi
        done
    fi

    # If total_size is still 0 but we have files, try using du as fallback
    if [[ $total_size -eq 0 ]] && [[ ${#files[@]} -gt 0 ]]; then
        # Use du to calculate directory size (more reliable for caches)
        if command -v du >/dev/null 2>&1; then
            local du_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
            if [[ -n "$du_size" ]] && [[ "$du_size" =~ ^[0-9]+$ ]]; then
                total_size=$((du_size * 1024))
            fi
        fi
    fi

    # Return: category|path|file_count|total_size
    echo "${category}|${path}|${#files[@]}|${total_size}"
}

# Show cleanup preview
show_cleanup_preview() {
    local min_age_days="${1:-0}"
    local categories=$(get_cleanup_categories)

    print_info "=========================================="
    print_info "Cleanup Preview"
    print_info "=========================================="
    print_info ""

    if [[ $min_age_days -gt 0 ]]; then
        print_info "Showing files older than $min_age_days days"
    else
        print_info "Showing all cleanable files"
    fi
    print_info ""

    # Count total categories for progress
    local category_array=($categories)
    local total_categories=${#category_array[@]}
    local current_category=0

    local total_files=0
    local total_size=0
    local results=()

    for category in $categories; do
        current_category=$((current_category + 1))

        # Show progress - use show_progress from common.sh if available
        local percent=$((current_category * 100 / total_categories))
        if [[ "$(type -t show_progress)" == "function" ]]; then
            show_progress "$percent" "Scanning: $category"
        else
            # Fallback if show_progress not available
            local filled=$((percent * 20 / 100))
            local bar=""
            local i=0
            while [[ $i -lt $filled ]]; do
                bar="${bar}▓"
                i=$((i + 1))
            done
            while [[ $i -lt 20 ]]; do
                bar="${bar}░"
                i=$((i + 1))
            done
            if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
                tput el 2>/dev/null || true
                echo -ne "\r[${bar}] ${percent}% - Scanning: $category"
            else
                echo "[${bar}] ${percent}% - Scanning: $category"
            fi
        fi

        local result=$(scan_cleanup_category "$category" "$min_age_days")
        if [[ -n "$result" ]]; then
            IFS='|' read -r cat_name path file_count size <<< "$result"
            results+=("$result")
            total_files=$((total_files + file_count))
            total_size=$((total_size + size))
        fi
    done

    # Clear progress line and add newline
    if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
        tput el 2>/dev/null || true
        echo ""
    else
        echo ""
    fi

    # Display results
    printf "%-20s %-40s %10s %15s\n" "Category" "Path" "Files" "Size"
    echo "--------------------------------------------------------------------------------"

    for result in "${results[@]}"; do
        IFS='|' read -r cat_name path file_count size <<< "$result"
        local size_formatted=""

        # Format size in MB (user preference)
        local size_mb=$((size / 1024 / 1024))
        if [[ $size_mb -ge 1024 ]]; then
            # If >= 1GB, show in GB
            local size_gb=$(awk "BEGIN {printf \"%.2f\", $size / 1073741824}")
            size_formatted="${size_gb} GB"
        else
            # Show in MB
            local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $size / 1048576}")
            size_formatted="${size_mb_float} MB"
        fi

        # Truncate long paths
        local display_path="$path"
        if [[ ${#display_path} -gt 38 ]]; then
            display_path="...${display_path: -35}"
        fi

        printf "%-20s %-40s %10s %15s\n" "$cat_name" "$display_path" "$file_count" "$size_formatted"
    done

    echo "--------------------------------------------------------------------------------"

    # Format total size in MB (user preference)
    local total_formatted=""
    local total_mb=$((total_size / 1024 / 1024))
    if [[ $total_mb -ge 1024 ]]; then
        # If >= 1GB, show in GB
        local total_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
        total_formatted="${total_gb} GB"
    else
        # Show in MB
        local total_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
        total_formatted="${total_mb_float} MB"
    fi

    printf "%-20s %-40s %10s %15s\n" "TOTAL" "" "$total_files" "$total_formatted"
    print_info ""
}

# Check if file is a development file
is_dev_file() {
    local file="$1"
    [[ -z "$file" ]] && return 1

    # Check for common development file patterns
    if [[ "$file" == *"/node_modules/"* ]] || \
       [[ "$file" == *"/__pycache__/"* ]] || \
       [[ "$file" == *"/.pytest_cache/"* ]] || \
       [[ "$file" == *"/.next/"* ]] || \
       [[ "$file" == *"/dist/"* ]] || \
       [[ "$file" == *"/build/"* ]] || \
       [[ "$file" == *"/target/"* ]] || \
       [[ "$file" == *"/.gradle/"* ]] || \
       [[ "$file" == *"/.mvn/"* ]] || \
       [[ "$file" == *"/.venv/"* ]] || \
       [[ "$file" == *"/venv/"* ]] || \
       [[ "$file" == *"/.cache/"* ]] || \
       [[ "$file" == *"/coverage/"* ]] || \
       [[ "$file" == *"/.nyc_output/"* ]] || \
       [[ "$file" == *"/.turbo/"* ]] || \
       [[ "$file" == *"/.parcel-cache/"* ]]; then
        return 0  # Is dev file
    fi

    # Check file extensions
    local ext="${file##*.}"
    if [[ "$ext" == "map" ]] || \
       [[ "$ext" == "tsbuildinfo" ]] || \
       [[ "$file" == *".log" ]] && [[ "$file" != *"/Library/Logs/"* ]]; then
        return 0  # Is dev file
    fi

    return 1  # Not a dev file
}

# Interactive cleanup file confirmation
cleanup_files_interactive() {
    local category="$1"
    local files=("${@:2}")
    local total_size=0
    local dev_files=()
    local dev_count=0

    if [[ ${#files[@]} -gt 0 ]]; then
        for file in "${files[@]}"; do
            if [[ -f "$file" ]]; then
                local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
                total_size=$((total_size + size))

                # Check if it's a dev file
                if is_dev_file "$file"; then
                    dev_files+=("$file")
                    dev_count=$((dev_count + 1))
                fi
            fi
        done
    fi

    # Format size in MB (user preference)
    local size_formatted=""
    local size_mb=$((total_size / 1024 / 1024))
    if [[ $size_mb -ge 1024 ]]; then
        # If >= 1GB, show in GB
        local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
        size_formatted="${size_gb} GB"
    else
        # Show in MB
        local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
        size_formatted="${size_mb_float} MB"
    fi

    print_warning "About to delete ${#files[@]} files from category: $category"
    print_info "Total size: $size_formatted"

    # Special warning for development files
    if [[ $dev_count -gt 0 ]]; then
        print_warning ""
        print_warning "⚠ WARNING: Found $dev_count development file(s) that will be deleted:"
        print_warning "  - node_modules, build files, caches, and other dev artifacts"
        print_warning ""
        if ! confirm "Delete development files? (y/N)" "N"; then
            log_info "User cancelled cleanup of development files for category: $category"
            return 1
        fi
    fi

    if [[ "$FORCE_MODE" == "true" ]] || is_dry_run; then
        if is_dry_run; then
            print_info "[DRY-RUN] Would delete ${#files[@]} files"
        else
            print_info "[FORCE MODE] Deleting ${#files[@]} files without confirmation"
        fi
        return 0
    fi

    if ! confirm "Delete these files? (y/N)" "N"; then
        log_info "User cancelled cleanup for category: $category"
        return 1
    fi

    return 0
}

delete_category_files() {
    local category="$1"
    local min_age_days="${2:-0}"

    # Safety check: never delete in dry-run or without confirmation
    if is_dry_run; then
        log_info "[DRY-RUN] Would delete files from category: $category"
        return 0
    fi

    # Handle special categories
    case "$category" in
        react_native)
            log_info "Cleaning React Native caches..."

            local cache_paths=(
                "${HOME}/.rncache"
                "${HOME}/Library/Caches/Metro"
                "${HOME}/Library/Caches/com.facebook.ReactNativeBuild"
                "/tmp/metro-*"
                "/tmp/haste-map-*"
                "/tmp/react-*"
            )

            # Calculate total size for confirmation
            local total_size=0
            local dirs_to_delete=()
            for cache_path in "${cache_paths[@]}"; do
                if [[ "$cache_path" == *"*"* ]]; then
                    while IFS= read -r dir; do
                        [[ -z "$dir" ]] || [[ ! -e "$dir" ]] && continue
                        dirs_to_delete+=("$dir")
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                            fi
                        fi
                    done < <(find "$(dirname "$cache_path")" -maxdepth 1 -name "$(basename "$cache_path")" 2>/dev/null)
                else
                    if [[ -e "$cache_path" ]]; then
                        dirs_to_delete+=("$cache_path")
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                            fi
                        fi
                    fi
                fi
            done

            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then
                log_info "No React Native caches found"
                return 0
            fi

            # Format size for display
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to delete ${#dirs_to_delete[@]} React Native cache locations"
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ WARNING: This will delete React Native caches:"
            print_warning "  - Metro bundler cache"
            print_warning "  - React Native build cache"
            print_warning "  - Temporary files"
            print_warning "  - These caches will be regenerated on next build"
            print_warning ""

            if ! confirm "Delete React Native caches? (y/N)" "N"; then
                log_info "User cancelled React Native cache deletion"
                return 1
            fi

            # Delete cache directories
            local deleted=0
            local failed=0
            for dir in "${dirs_to_delete[@]}"; do
                if [[ -e "$dir" ]]; then
                    if rm -rf "$dir" 2>/dev/null; then
                        deleted=$((deleted + 1))
                        log_debug "Deleted: $dir"
                    else
                        failed=$((failed + 1))
                        log_warn "Failed to delete: $dir"
                    fi
                fi
            done

            log_success "Deleted $deleted React Native cache locations"
            [[ $failed -gt 0 ]] && log_warn "$failed locations could not be deleted"
            return 0
            ;;
        android_studio)
            log_info "Cleaning Android Studio caches..."

            local cache_paths=(
                "${HOME}/.android/cache"
                "${HOME}/.android/build-cache"
            )

            # Add macOS-specific paths
            if is_macos; then
                cache_paths+=("${HOME}/Library/Caches/AndroidStudio*")
            fi

            # Calculate total size
            local total_size=0
            local dirs_to_delete=()
            for cache_path in "${cache_paths[@]}"; do
                if [[ "$cache_path" == *"*"* ]]; then
                    while IFS= read -r dir; do
                        [[ -z "$dir" ]] || [[ ! -e "$dir" ]] && continue
                        dirs_to_delete+=("$dir")
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                            fi
                        fi
                    done < <(find "$(dirname "$cache_path")" -maxdepth 1 -name "$(basename "$cache_path")" -type d 2>/dev/null)
                else
                    if [[ -e "$cache_path" ]]; then
                        dirs_to_delete+=("$cache_path")
                        if command -v du >/dev/null 2>&1; then
                            local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                            if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                                total_size=$((total_size + dir_size * 1024))
                            fi
                        fi
                    fi
                fi
            done

            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then
                log_info "No Android Studio caches found"
                return 0
            fi

            # Format size
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to delete ${#dirs_to_delete[@]} Android Studio cache locations"
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ WARNING: This will delete Android Studio caches:"
            print_warning "  - Build caches"
            print_warning "  - IDE caches"
            print_warning "  - These will be regenerated automatically"
            print_warning ""

            if ! confirm "Delete Android Studio caches? (y/N)" "N"; then
                log_info "User cancelled Android Studio cache deletion"
                return 1
            fi

            # Delete cache directories
            local deleted=0
            local failed=0
            for dir in "${dirs_to_delete[@]}"; do
                if [[ -e "$dir" ]]; then
                    if rm -rf "$dir" 2>/dev/null; then
                        deleted=$((deleted + 1))
                        log_debug "Deleted: $dir"
                    else
                        failed=$((failed + 1))
                        log_warn "Failed to delete: $dir"
                    fi
                fi
            done

            log_success "Deleted $deleted Android Studio cache locations"
            [[ $failed -gt 0 ]] && log_warn "$failed locations could not be deleted"
            return 0
            ;;
        gradle)
            log_info "Cleaning Gradle caches..."

            local cache_path="${HOME}/.gradle/caches"

            if [[ ! -e "$cache_path" ]]; then
                log_info "No Gradle caches found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + dir_size * 1024))
                fi
            fi

            # Format size
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to delete Gradle caches"
            print_info "Location: $cache_path"
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ WARNING: This will delete Gradle caches:"
            print_warning "  - Downloaded dependencies will be removed"
            print_warning "  - They will be re-downloaded on next build"
            print_warning ""

            if ! confirm "Delete Gradle caches? (y/N)" "N"; then
                log_info "User cancelled Gradle cache deletion"
                return 1
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Gradle caches"
            else
                log_warn "Failed to delete Gradle caches"
                return 1
            fi

            return 0
            ;;
        ios_simulators)
            if ! is_macos; then
                log_warn "iOS Simulator cleanup is only available on macOS"
                return 1
            fi

            log_info "Cleaning iOS Simulator caches..."

            local cache_paths=(
                "${HOME}/Library/Developer/CoreSimulator/Caches"
            )

            # Calculate size
            local total_size=0
            local dirs_to_delete=()
            for cache_path in "${cache_paths[@]}"; do
                if [[ -e "$cache_path" ]]; then
                    dirs_to_delete+=("$cache_path")
                    if command -v du >/dev/null 2>&1; then
                        local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}')
                        if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + dir_size * 1024))
                        fi
                    fi
                fi
            done

            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then
                log_info "No iOS Simulator caches found"
                return 0
            fi

            # Format size
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to delete iOS Simulator caches"
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ WARNING: This will delete iOS Simulator caches:"
            print_warning "  - Simulator app data may be cleared"
            print_warning "  - Caches will be regenerated automatically"
            print_warning ""

            if ! confirm "Delete iOS Simulator caches? (y/N)" "N"; then
                log_info "User cancelled iOS Simulator cache deletion"
                return 1
            fi

            # Delete cache directories
            local deleted=0
            local failed=0
            for dir in "${dirs_to_delete[@]}"; do
                if [[ -e "$dir" ]]; then
                    if rm -rf "$dir" 2>/dev/null; then
                        deleted=$((deleted + 1))
                        log_debug "Deleted: $dir"
                    else
                        failed=$((failed + 1))
                        log_warn "Failed to delete: $dir"
                    fi
                fi
            done

            log_success "Deleted $deleted iOS Simulator cache locations"
            [[ $failed -gt 0 ]] && log_warn "$failed locations could not be deleted"
            return 0
            ;;
        xcode_archives)
            if ! is_macos; then
                log_warn "Xcode Archives cleanup is only available on macOS"
                return 1
            fi

            log_info "Cleaning Xcode Archives..."

            local path="${HOME}/Library/Developer/Xcode/Archives"

            if [[ ! -e "$path" ]]; then
                log_info "No Xcode Archives found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + dir_size * 1024))
                fi
            fi

            # Format size
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to delete Xcode Archives"
            print_info "Location: $path"
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ CRITICAL WARNING: This will delete Xcode Archives:"
            print_warning "  - App archives for App Store submissions"
            print_warning "  - Debug symbols for crash reports"
            print_warning "  - Make sure you have backups or don't need these archives"
            print_warning ""

            if ! confirm "Delete Xcode Archives? (y/N)" "N"; then
                log_info "User cancelled Xcode Archives deletion"
                return 1
            fi

            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Xcode Archives"
            else
                log_warn "Failed to delete Xcode Archives"
                return 1
            fi

            return 0
            ;;
        xcode_device_support)
            if ! is_macos; then
                log_warn "Xcode Device Support cleanup is only available on macOS"
                return 1
            fi

            log_info "Cleaning Xcode Device Support..."

            local path="${HOME}/Library/Developer/Xcode/iOS DeviceSupport"

            if [[ ! -e "$path" ]]; then
                log_info "No Xcode Device Support found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((total_size + dir_size * 1024))
                fi
            fi

            # Format size
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to delete Xcode Device Support"
            print_info "Location: $path"
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ WARNING: This will delete iOS Device Support files:"
            print_warning "  - Debug symbols for physical iOS devices"
            print_warning "  - These will be re-downloaded when connecting devices again"
            print_warning ""

            if ! confirm "Delete Xcode Device Support? (y/N)" "N"; then
                log_info "User cancelled Xcode Device Support deletion"
                return 1
            fi

            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Xcode Device Support"
            else
                log_warn "Failed to delete Xcode Device Support"
                return 1
            fi

            return 0
            ;;
        node_modules)
            # Find all node_modules directories (not just files)
            local node_modules_dirs=()
            local search_paths=("${HOME}/dev" "${HOME}/projects" "${HOME}/workspace" "${HOME}/code" "${HOME}/Documents" "${HOME}/Desktop")

            log_info "Finding node_modules directories..."
            for base_path in "${search_paths[@]}"; do
                [[ ! -d "$base_path" ]] && continue
                while IFS= read -r dir; do
                    [[ -z "$dir" ]] || [[ ! -d "$dir" ]] && continue
                    # Skip if inside protected directories (.git, .claude, .cursor, .task-flow)
                    local skip_dir=false
                    local protected_dirs=(".git" ".claude" ".cursor" ".task-flow")
                    for protected in "${protected_dirs[@]}"; do
                        if [[ "$dir" == *"/${protected}/"* ]] || [[ "$dir" == *"/${protected}" ]]; then
                            skip_dir=true
                            break
                        fi
                    done
                    if [[ "$skip_dir" == "false" ]]; then
                        node_modules_dirs+=("$dir")
                    fi
                done < <(find "$base_path" \( -name ".git" -o -name ".claude" -o -name ".cursor" -o -name ".task-flow" \) -prune -o -maxdepth 4 -type d -name "node_modules" -print 2>/dev/null)
            done

            if [[ ${#node_modules_dirs[@]} -eq 0 ]]; then
                log_info "No node_modules directories found to delete"
                return 0
            fi

            # Calculate total size for confirmation
            local total_size=0
            local dir_count=${#node_modules_dirs[@]}
            for dir in "${node_modules_dirs[@]}"; do
                if command -v du >/dev/null 2>&1; then
                    local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                    if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                        total_size=$((total_size + dir_size * 1024))
                    fi
                fi
            done

            # Format size for display
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to delete $dir_count node_modules directories"
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ WARNING: This will delete entire node_modules directories"
            print_warning "  - All dependencies will be removed"
            print_warning "  - You can restore them with: npm install, yarn install, or pnpm install"
            print_warning ""

            if ! confirm "Delete all node_modules directories? (y/N)" "N"; then
                log_info "User cancelled node_modules deletion"
                return 1
            fi

            # Delete entire node_modules directories
            local deleted=0
            local failed=0
            for dir in "${node_modules_dirs[@]}"; do
                if [[ -d "$dir" ]]; then
                    if rm -rf "$dir" 2>/dev/null; then
                        deleted=$((deleted + 1))
                        log_debug "Deleted: $dir"
                    else
                        failed=$((failed + 1))
                        log_warn "Failed to delete: $dir"
                    fi
                fi
            done

            log_success "Deleted $deleted node_modules directories"
            [[ $failed -gt 0 ]] && log_warn "$failed directories could not be deleted"
            return 0
            ;;
        build_artifacts)
            local files=()
            while IFS= read -r file; do
                [[ -n "$file" ]] && files+=("$file")
            done < <(scan_build_artifacts "$min_age_days")

            if [[ ${#files[@]} -eq 0 ]]; then
                log_info "No build artifacts found to delete"
                return 0
            fi

            if ! cleanup_files_interactive "$category" "${files[@]}"; then
                return 1
            fi

            local deleted=0
            local failed=0
            for file in "${files[@]}"; do
                if [[ -f "$file" ]] && rm -f "$file" 2>/dev/null; then
                    deleted=$((deleted + 1))
                else
                    failed=$((failed + 1))
                fi
            done

            log_success "Deleted $deleted build artifact files"
            [[ $failed -gt 0 ]] && log_warn "$failed files could not be deleted"
            return 0
            ;;
        volumes)
            if ! command -v docker >/dev/null 2>&1; then
                log_warn "Docker not found, skipping volume cleanup"
                return 1
            fi

            log_info "Listing Docker volumes..."
            local volumes=$(docker volume ls -q 2>/dev/null)
            if [[ -z "$volumes" ]]; then
                log_info "No Docker volumes found"
                return 0
            fi

            print_warning "About to remove Docker volumes (unused volumes will be removed)"
            print_info "Volumes found: $(echo "$volumes" | wc -l | tr -d ' ')"
            if ! confirm "Remove unused Docker volumes? (y/N)" "N"; then
                return 1
            fi

            # Use timeout to prevent hanging, and check if Docker is responsive
            # First check if Docker is running
            if ! docker info >/dev/null 2>&1; then
                log_warn "Docker is not running or not accessible"
                return 1
            fi

            # Try to prune with timeout
            local prune_success=false
            if command -v timeout >/dev/null 2>&1; then
                # Use timeout command (Linux/GNU)
                if timeout 10 docker volume prune -f >/dev/null 2>&1; then
                    prune_success=true
                else
                    log_warn "Docker volume prune timed out or failed"
                fi
            elif command -v gtimeout >/dev/null 2>&1; then
                # Use gtimeout (macOS with coreutils)
                if gtimeout 10 docker volume prune -f >/dev/null 2>&1; then
                    prune_success=true
                else
                    log_warn "Docker volume prune timed out or failed"
                fi
            else
                # Fallback: run in background and kill if takes too long
                docker volume prune -f >/dev/null 2>&1 &
                local prune_pid=$!
                local waited=0
                while kill -0 "$prune_pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
                    sleep 1
                    waited=$((waited + 1))
                done

                if kill -0 "$prune_pid" 2>/dev/null; then
                    # Still running after 10 seconds, kill it
                    kill "$prune_pid" 2>/dev/null || true
                    wait "$prune_pid" 2>/dev/null || true
                    log_warn "Docker volume prune took too long, cancelled"
                else
                    wait "$prune_pid" 2>/dev/null || true
                    prune_success=true
                fi
            fi

            if [[ "$prune_success" == "true" ]]; then
                log_success "Docker volumes cleaned"
            fi

            log_success "Docker volumes cleaned"
            return 0
            ;;
        orphaned_apps)
            if ! is_macos; then
                log_warn "Orphaned apps cleanup is only available on macOS"
                return 1
            fi

            log_info "Finding orphaned applications (deleted apps with remaining configs)..."

            # Find orphaned app directories
            local orphaned_dirs=()
            while IFS= read -r dir; do
                [[ -n "$dir" ]] && orphaned_dirs+=("$dir")
            done < <(find_orphaned_apps)

            if [[ ${#orphaned_dirs[@]} -eq 0 ]]; then
                log_info "No orphaned applications found"
                return 0
            fi

            # Calculate total size
            local total_size=0
            for dir in "${orphaned_dirs[@]}"; do
                if [[ -d "$dir" ]] && command -v du >/dev/null 2>&1; then
                    local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
                    if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                        total_size=$((total_size + dir_size * 1024))
                    fi
                fi
            done

            # Format size
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            # Show list of orphaned apps
            print_warning "Found ${#orphaned_dirs[@]} orphaned application(s):"
            for dir in "${orphaned_dirs[@]}"; do
                local app_name=$(basename "$dir")
                local app_size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}' || echo "unknown")
                print_info "  - $app_name ($app_size)"
            done
            print_info ""
            print_info "Total size: $size_formatted"
            print_warning ""
            print_warning "⚠ WARNING: This will delete Application Support and Preferences for deleted apps"
            print_warning "  - Application Support: ~/Library/Application Support/[app]"
            print_warning "  - Preferences: ~/Library/Preferences/[app]*.plist"
            print_warning ""

            if ! confirm "Delete orphaned application configurations? (y/N)" "N"; then
                log_info "User cancelled orphaned apps cleanup"
                return 1
            fi

            # Delete Application Support directories
            local deleted=0
            local failed=0
            local app_support="${HOME}/Library/Application Support"
            local preferences="${HOME}/Library/Preferences"

            for dir in "${orphaned_dirs[@]}"; do
                local app_name=$(basename "$dir")

                # Delete Application Support directory
                if [[ -d "$dir" ]]; then
                    if rm -rf "$dir" 2>/dev/null; then
                        deleted=$((deleted + 1))
                        log_debug "Deleted Application Support: $app_name"
                    else
                        failed=$((failed + 1))
                        log_warn "Failed to delete Application Support: $app_name"
                    fi
                fi

                # Delete Preferences files (by bundle ID or app name)
                if [[ -d "$preferences" ]]; then
                    # Try to find preferences by app name or bundle ID
                    local pref_pattern=""
                    if [[ "$app_name" =~ ^com\. ]]; then
                        # It's a bundle ID
                        pref_pattern="$app_name"
                    else
                        # Try common bundle ID patterns
                        pref_pattern="*${app_name}*"
                    fi

                    # Delete matching preference files
                    while IFS= read -r pref_file; do
                        [[ -f "$pref_file" ]] && rm -f "$pref_file" 2>/dev/null && log_debug "Deleted preference: $(basename "$pref_file")"
                    done < <(find "$preferences" -maxdepth 1 -name "${pref_pattern}.plist" 2>/dev/null)
                fi
            done

            log_success "Deleted $deleted orphaned application configurations"
            [[ $failed -gt 0 ]] && log_warn "$failed configurations could not be deleted"
            return 0
            ;;
    esac

    local path=""
    if command -v get_category_path >/dev/null 2>&1; then
        path=$(get_category_path "$category")
    else
        log_error "get_category_path function not available"
        return 1
    fi

    if [[ -z "$path" ]] || [[ ! -e "$path" ]]; then
        log_warn "Category $category: path not found ($path)"
        return 1
    fi

    # Special handling for browser_trash - use macOS native command for reliability
    if [[ "$category" == "browser_trash" ]]; then
        if is_macos; then
            # Count items in trash first
            local trash_items=()
            while IFS= read -r item; do
                [[ -n "$item" ]] && trash_items+=("$item")
            done < <(find "$path" -mindepth 1 2>/dev/null)

            if [[ ${#trash_items[@]} -eq 0 ]]; then
                log_info "Trash is already empty"
                return 0
            fi

            # Calculate total size
            local total_size=0
            for item in "${trash_items[@]}"; do
                if [[ -e "$item" ]]; then
                    if command -v du >/dev/null 2>&1; then
                        local item_size=$(du -sk "$item" 2>/dev/null | awk '{print $1}')
                        if [[ -n "$item_size" ]] && [[ "$item_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + item_size * 1024))
                        fi
                    fi
                fi
            done

            # Format size
            local size_mb=$((total_size / 1024 / 1024))
            local size_formatted=""
            if [[ $size_mb -ge 1024 ]]; then
                local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                size_formatted="${size_gb} GB"
            else
                local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                size_formatted="${size_mb_float} MB"
            fi

            print_warning "About to empty trash: ${#trash_items[@]} items"
            print_info "Total size: $size_formatted"

            if ! confirm "Empty trash? (y/N)" "N"; then
                log_info "User cancelled trash cleanup"
                return 1
            fi

            # Use macOS native command to empty trash (most reliable method)
            if command -v osascript >/dev/null 2>&1; then
                log_info "Emptying trash using macOS Finder..."
                if osascript -e 'tell application "Finder" to empty trash' 2>/dev/null; then
                    log_success "Trash emptied successfully"
                    return 0
                else
                    log_warn "Failed to empty trash using Finder, trying manual deletion..."
                fi
            fi

            # Fallback: manual deletion if osascript fails
            local deleted=0
            local failed=0
            for item in "${trash_items[@]}"; do
                if [[ -e "$item" ]]; then
                    # Use rm -rf with force to handle locked files
                    if rm -rf "$item" 2>/dev/null || sudo rm -rf "$item" 2>/dev/null; then
                        deleted=$((deleted + 1))
                    else
                        failed=$((failed + 1))
                        log_warn "Failed to delete: $item (may be locked)"
                    fi
                fi
            done

            log_success "Deleted $deleted items from trash"
            [[ $failed -gt 0 ]] && log_warn "$failed items could not be deleted (may require manual deletion)"
            return 0
        else
            # Linux: use standard deletion
            local trash_items=()
            while IFS= read -r item; do
                [[ -n "$item" ]] && trash_items+=("$item")
            done < <(find "$path" -mindepth 1 2>/dev/null)

            if [[ ${#trash_items[@]} -eq 0 ]]; then
                log_info "Trash is already empty"
                return 0
            fi

            print_warning "About to empty trash: ${#trash_items[@]} items"
            if ! confirm "Empty trash? (y/N)" "N"; then
                return 1
            fi

            local deleted=0
            local failed=0
            for item in "${trash_items[@]}"; do
                if [[ -e "$item" ]] && rm -rf "$item" 2>/dev/null; then
                    deleted=$((deleted + 1))
                else
                    failed=$((failed + 1))
                fi
            done

            log_success "Deleted $deleted items from trash"
            [[ $failed -gt 0 ]] && log_warn "$failed items could not be deleted"
            return 0
        fi
    fi

    # Get list of files to delete (for other categories)
    local files=()
    if [[ $min_age_days -gt 0 ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if ! should_exclude_file "$file"; then
                files+=("$file")
            fi
        done < <(find "$path" -type f -mtime +${min_age_days} -print0 2>/dev/null | xargs -0)
    else
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if ! should_exclude_file "$file"; then
                files+=("$file")
            fi
        done < <(find "$path" -type f -print0 2>/dev/null | xargs -0)
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        log_info "No files found to delete in category: $category"
        return 0
    fi

    # Interactive confirmation
    if [[ ${#files[@]} -gt 0 ]]; then
        if ! cleanup_files_interactive "$category" "${files[@]}"; then
            return 1
        fi
    fi

    # Delete files
    local deleted=0
    local failed=0

    if [[ ${#files[@]} -gt 0 ]]; then
        for file in "${files[@]}"; do
            if [[ -f "$file" ]]; then
                if rm -f "$file" 2>/dev/null; then
                    deleted=$((deleted + 1))
                else
                    failed=$((failed + 1))
                    log_warn "Failed to delete: $file"
                fi
            fi
        done
    fi

    log_success "Deleted $deleted files from category: $category"
    if [[ $failed -gt 0 ]]; then
        log_warn "$failed files could not be deleted"
    fi

    return 0
}

# Export functions
export -f get_cleanup_categories
export -f find_orphaned_apps
export -f scan_node_modules
export -f scan_build_artifacts
export -f scan_cleanup_category
export -f show_cleanup_preview
export -f is_dev_file
export -f cleanup_files_interactive
export -f delete_category_files
