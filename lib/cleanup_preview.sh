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

# Source disk_analysis.sh if available
if [[ -z "${DISK_ANALYSIS_SH_LOADED:-}" ]]; then
    _cleanup_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_cleanup_script_dir}/disk_analysis.sh" ]]; then
        source "${_cleanup_script_dir}/disk_analysis.sh"
    fi
fi

FORCE_MODE="${FORCE_MODE:-false}"
SKIP_CATEGORY_CONFIRM="${SKIP_CATEGORY_CONFIRM:-false}"
ALL_USERS="${ALL_USERS:-false}"

# Helper function to get the correct HOME directory
# Uses HOME_OVERRIDE if set (for multi-user cleanup), otherwise uses $HOME
get_user_home() {
    echo "${HOME_OVERRIDE:-$HOME}"
}

# ============ Cleanup Category Functions ============

get_cleanup_categories() {
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

# Find orphaned applications (apps deleted but configs remain)
find_orphaned_apps() {
    local orphaned_apps=()

    if ! is_macos; then
        # Linux: check ~/.config and ~/.local/share
        local config_dir="$(get_user_home)/.config"

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
        local app_support="$(get_user_home)/Library/Application Support"

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
        "$(get_user_home)/dev"
        "$(get_user_home)/projects"
        "$(get_user_home)/workspace"
        "$(get_user_home)/code"
        "$(get_user_home)/Documents"
        "$(get_user_home)/Desktop"
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
        "$(get_user_home)/dev"
        "$(get_user_home)/projects"
        "$(get_user_home)/workspace"
        "$(get_user_home)/code"
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
                "$(get_user_home)/.rncache"
                "$(get_user_home)/Library/Caches/Metro"
                "$(get_user_home)/Library/Caches/com.facebook.ReactNativeBuild"
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
                "$(get_user_home)/.android/cache"
                "$(get_user_home)/.android/build-cache"
                "$(get_user_home)/Library/Caches/AndroidStudio*"
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
            local cache_path="$(get_user_home)/.gradle/caches"
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
                "$(get_user_home)/Library/Developer/CoreSimulator/Caches"
                "$(get_user_home)/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches"
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

            local path="$(get_user_home)/Library/Developer/Xcode/Archives"
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

            local path="$(get_user_home)/Library/Developer/Xcode/iOS DeviceSupport"
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
            local search_paths=("$(get_user_home)/dev" "$(get_user_home)/projects" "$(get_user_home)/workspace" "$(get_user_home)/code" "$(get_user_home)/Documents" "$(get_user_home)/Desktop")

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
            local search_paths=("$(get_user_home)/dev" "$(get_user_home)/projects" "$(get_user_home)/workspace" "$(get_user_home)/code")
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
        npm_cache)
            local cache_path="$(get_user_home)/.npm"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        expo_cache)
            local cache_path="$(get_user_home)/.expo"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        vscode_cache)
            local cache_paths=()
            if is_macos; then
                cache_paths=(
                    "$(get_user_home)/Library/Application Support/Code/Cache"
                    "$(get_user_home)/Library/Application Support/Code/CachedData"
                    "$(get_user_home)/Library/Application Support/Code/CachedExtensions"
                    "$(get_user_home)/Library/Application Support/Code/logs"
                )
            else
                cache_paths=(
                    "$(get_user_home)/.config/Code/Cache"
                    "$(get_user_home)/.config/Code/CachedData"
                    "$(get_user_home)/.config/Code/CachedExtensions"
                    "$(get_user_home)/.config/Code/logs"
                )
            fi

            local total_size=0
            local file_count=0
            for cache_path in "${cache_paths[@]}"; do
                if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                    local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                    if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                        total_size=$((total_size + dir_size * 1024))
                        file_count=$((file_count + dir_size * 20))
                    fi
                fi
            done

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|VS Code cache|${file_count}|${total_size}"
            return 0
            ;;
        nvm_cache)
            local cache_path="$(get_user_home)/.nvm/.cache"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        cocoapods_cache)
            if ! is_macos; then
                return 0
            fi

            local cache_path="$(get_user_home)/.cocoapods"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        yarn_cache)
            local cache_path="$(get_user_home)/.yarn/cache"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        pip_cache)
            local cache_path=""
            if is_macos; then
                cache_path="$(get_user_home)/Library/Caches/pip"
            else
                cache_path="$(get_user_home)/.cache/pip"
            fi

            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        gem_cache)
            local cache_path="$(get_user_home)/.gem/cache"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        homebrew_cache)
            if ! is_macos; then
                return 0
            fi

            local cache_path=""
            if command -v brew >/dev/null 2>&1; then
                cache_path=$(brew --cache 2>/dev/null || echo "")
            fi

            if [[ -z "$cache_path" ]]; then
                cache_path="$(get_user_home)/Library/Caches/Homebrew"
            fi

            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        # New categories for scan
        nuget_cache)
            local cache_path="$(get_user_home)/.nuget"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        dotnet_cache)
            local cache_path="$(get_user_home)/.dotnet"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        application_support_google)
            local path="$(get_user_home)/Library/Application Support/Google"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        application_support_cursor)
            local path="$(get_user_home)/Library/Application Support/Cursor"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        application_support_wallpaper)
            local path="$(get_user_home)/Library/Application Support/com.apple.wallpaper"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        containers_cleanup)
            local containers_dir="$(get_user_home)/Library/Containers"
            local orphaned_count=0
            local total_size=0

            if [[ -d "$containers_dir" ]]; then
                while IFS= read -r container; do
                    [[ -z "$container" ]] || [[ ! -d "$container" ]] && continue
                    local bundle_id=$(basename "$container")
                    local app_found=false
                    
                    if [[ -d "/Applications/${bundle_id}.app" ]]; then
                        continue
                    fi
                    
                    orphaned_count=$((orphaned_count + 1))
                    if command -v du >/dev/null 2>&1; then
                        local dir_size=$(du -sk "$container" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                        if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + dir_size * 1024))
                        fi
                    fi
                done < <(find "$containers_dir" -maxdepth 1 -type d ! -path "$containers_dir" 2>/dev/null)
            fi

            echo "${category}|Orphaned containers|${orphaned_count}|${total_size}"
            return 0
            ;;
        homebrew_cleanup)
            echo "${category}|Homebrew cleanup command|0|0"
            return 0
            ;;
        xcode_app)
            if ! is_macos; then
                return 0
            fi
            local app_path="/Applications/Xcode.app"
            local total_size=0
            local file_count=0

            if [[ -e "$app_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$app_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size / 100))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${app_path}|${file_count}|${total_size}"
            return 0
            ;;
        android_studio_app)
            if ! is_macos; then
                return 0
            fi
            local app_path="/Applications/Android Studio.app"
            local total_size=0
            local file_count=0

            if [[ -e "$app_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$app_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size / 100))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${app_path}|${file_count}|${total_size}"
            return 0
            ;;
        android_library)
            local path="$(get_user_home)/Library/Android"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        android_application_support)
            local base_path="$(get_user_home)/Library/Application Support/Google"
            local total_size=0
            local file_count=0

            while IFS= read -r dir; do
                [[ -n "$dir" ]] && [[ -d "$dir" ]] || continue
                if command -v du >/dev/null 2>&1; then
                    local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                    if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                        total_size=$((total_size + dir_size * 1024))
                        file_count=$((file_count + dir_size * 20))
                    fi
                fi
            done < <(find "$base_path" -maxdepth 1 -name "AndroidStudio*" -type d 2>/dev/null)

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|Android Studio Application Support|${file_count}|${total_size}"
            return 0
            ;;
        gradle_full)
            local cache_path="$(get_user_home)/.gradle"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        yarn_full)
            local cache_path="$(get_user_home)/.yarn"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        nvm_full)
            local cache_path="$(get_user_home)/.nvm"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        docker_full)
            local cache_path="$(get_user_home)/.docker"
            local total_size=0
            local file_count=0

            if [[ -e "$cache_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${cache_path}|${file_count}|${total_size}"
            return 0
            ;;
        large_directories)
            echo "${category}|Scan mode|0|0"
            return 0
            ;;
        dev_directory)
            local dev_path="$(get_user_home)/dev"
            local total_size=0
            local file_count=0

            if [[ -e "$dev_path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$dev_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${dev_path}|${file_count}|${total_size}"
            return 0
            ;;
        xcode_developer_full)
            if ! is_macos; then
                return 0
            fi
            local path="$(get_user_home)/Library/Developer/Xcode"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        xcode_simulator_full)
            if ! is_macos; then
                return 0
            fi
            local path="$(get_user_home)/Library/Developer/CoreSimulator"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        xcode_command_line_tools)
            if ! is_macos; then
                return 0
            fi
            local path="/Library/Developer/CommandLineTools"
            local total_size=0
            local file_count=0

            if [[ -e "$path" ]] && command -v du >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
                local dir_size=$(sudo du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$((dir_size * 1024))
                    file_count=$((dir_size * 20))
                fi
            fi

            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            return 0
            ;;
        flutter_cache)
            local path="$(get_user_home)/.pub-cache"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 5))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        swiftpm_cache)
            local path="$(get_user_home)/Library/Caches/org.swift.swiftpm"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 5))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        xcode_sim_logs)
            local total_size=0 file_count=0
            local paths=("$(get_user_home)/Library/Logs/CoreSimulator" "$(get_user_home)/Library/Logs/DiagnosticReports")
            for p in "${paths[@]}"; do
                [[ ! -e "$p" ]] && continue
                local sz=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024)) && file_count=$((file_count + sz * 2))
            done
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|Xcode/Simulator logs|${file_count}|${total_size}"
            ;;

        carthage_cache)
            local path="$(get_user_home)/Library/Caches/org.carthage.CarthageKit"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 5))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        ruby_bundler_cache)
            local path="$(get_user_home)/.bundle/cache"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 5))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        turborepo_cache)
            local path="$(get_user_home)/.turbo"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 5))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        jest_cache)
            local total_size=0 file_count=0
            while IFS= read -r d; do
                local sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024)) && file_count=$((file_count + sz * 2))
            done < <(find /tmp -maxdepth 1 -name "jest-*" -type d 2>/dev/null)
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|/tmp/jest-*|${file_count}|${total_size}"
            ;;

        playwright_cache)
            local path
            if is_macos; then path="$(get_user_home)/Library/Caches/ms-playwright"
            else path="$(get_user_home)/.cache/ms-playwright"; fi
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 2))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        cypress_cache)
            local path="$(get_user_home)/.cache/Cypress"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 2))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        pnpm_store)
            local path="$(get_user_home)/.pnpm-store"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 10))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        bun_cache)
            local path="$(get_user_home)/.bun/install/cache"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz * 5))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        android_project_builds)
            local total_size=0 file_count=0
            local search_paths=("$(get_user_home)/dev" "$(get_user_home)/projects" "$(get_user_home)/workspace" "$(get_user_home)/code")
            for base in "${search_paths[@]}"; do
                [[ ! -d "$base" ]] && continue
                while IFS= read -r d; do
                    local sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
                    [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024)) && file_count=$((file_count + sz))
                done < <(find "$base" -maxdepth 6 -type d -name "build" -path "*/app/build" 2>/dev/null | head -20)
            done
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|Android project build dirs|${file_count}|${total_size}"
            ;;

        ios_project_builds)
            local total_size=0 file_count=0
            local search_paths=("$(get_user_home)/dev" "$(get_user_home)/projects" "$(get_user_home)/workspace" "$(get_user_home)/code")
            for base in "${search_paths[@]}"; do
                [[ ! -d "$base" ]] && continue
                while IFS= read -r d; do
                    local sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
                    [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024)) && file_count=$((file_count + sz))
                done < <(find "$base" -maxdepth 6 -type d -name "build" \( -path "*/ios/build" -o -path "*/Build/Products" \) 2>/dev/null | head -20)
            done
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|iOS project build dirs|${file_count}|${total_size}"
            ;;

        android_avd)
            local path="$(get_user_home)/.android/avd"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;

        android_sdk_old)
            local base="$(get_user_home)/Library/Android/sdk/platforms"
            local total_size=0 file_count=0
            if [[ -d "$base" ]]; then
                local sz=$(du -sk "$base" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${base}|${file_count}|${total_size}"
            ;;

        ios_simulator_devices)
            if ! is_macos; then echo "${category}||0|0"; return 0; fi
            local path="$(get_user_home)/Library/Developer/CoreSimulator/Devices"
            local total_size=0 file_count=0
            if [[ -e "$path" ]]; then
                local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
                [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((sz * 1024)) && file_count=$((sz))
            fi
            [[ $file_count -eq 0 ]] && file_count=1
            echo "${category}|${path}|${file_count}|${total_size}"
            ;;
    esac

    if command -v get_category_path >/dev/null 2>&1; then
        path=$(get_category_path "$category")
    else
        case "$category" in
            caches)
                path=$(is_macos && echo "$(get_user_home)/Library/Caches" || echo "$(get_user_home)/.cache")
                ;;
            logs)
                path=$(is_macos && echo "$(get_user_home)/Library/Logs" || echo "/var/log")
                ;;
            # downloads removed - too dangerous, may contain important user files
            # downloads)
            #     path="${HOME}/Downloads"
            #     ;;
            temp)
                path="/tmp"
                ;;
            browser_trash)
                path=$(is_macos && echo "$(get_user_home)/.Trash" || echo "$(get_user_home)/.local/share/Trash")
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

    # Skip all confirmations if SKIP_CATEGORY_CONFIRM is set
    if [[ "$FORCE_MODE" == "true" ]] || is_dry_run || [[ "$SKIP_CATEGORY_CONFIRM" == "true" ]]; then
        if is_dry_run; then
            print_info "[DRY-RUN] Would delete ${#files[@]} files"
        else
            log_info "Deleting ${#files[@]} files from category: $category"
        fi
        return 0
    fi

    # Show warnings and ask for confirmation only if not skipping
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

    if ! confirm "Delete these files? (y/N)" "N"; then
        log_info "User cancelled cleanup for category: $category"
        return 1
    fi

    return 0
}

delete_category_files() {
    local category="$1"
    local min_age_days="${2:-0}"

    # Safety check for dry-run (except for trash which needs special handling)
    if is_dry_run && [[ "$category" != "browser_trash" ]]; then
        log_info "[DRY-RUN] Would delete files from category: $category"
        return 0
    fi

    # Check whitelist/blacklist
    local path=""
    if command -v get_category_path >/dev/null 2>&1; then
        path=$(get_category_path "$category")
    fi
    
    if [[ -n "$path" ]] && command -v should_skip_path >/dev/null 2>&1; then
        if should_skip_path "$path"; then
            log_info "Skipping whitelisted/protected path: $path"
            return 0
        fi
    fi

    # Show initial progress message (visible to user)
    if [[ "$QUIET" != "true" ]]; then
        echo "  → Analyzing $category..." >&2
    fi

    # Handle special categories
    case "$category" in
        react_native)
            log_info "Cleaning React Native caches..."

            local cache_paths=(
                "$(get_user_home)/.rncache"
                "$(get_user_home)/Library/Caches/Metro"
                "$(get_user_home)/Library/Caches/com.facebook.ReactNativeBuild"
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting ${#dirs_to_delete[@]} React Native cache locations ($size_formatted)"
            fi

            # Delete cache directories
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting ${#dirs_to_delete[@]} cache location(s)..." >&2
            fi

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
            if [[ "$QUIET" != "true" ]]; then
                echo "  ✓ React Native cache cleaned ($size_formatted)" >&2
            fi
            [[ $failed -gt 0 ]] && log_warn "$failed locations could not be deleted"
            return 0
            ;;
        android_studio)
            log_info "Cleaning Android Studio caches..."

            local cache_paths=(
                "$(get_user_home)/.android/cache"
                "$(get_user_home)/.android/build-cache"
            )

            # Add macOS-specific paths
            if is_macos; then
                cache_paths+=("$(get_user_home)/Library/Caches/AndroidStudio*")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting ${#dirs_to_delete[@]} Android Studio cache locations ($size_formatted)"
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

            local cache_path="$(get_user_home)/.gradle/caches"

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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting Gradle caches ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Gradle cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Gradle caches"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Gradle cache cleaned ($size_formatted)" >&2
                fi
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
                "$(get_user_home)/Library/Developer/CoreSimulator/Caches"
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting iOS Simulator caches ($size_formatted)"
            fi

            # Delete cache directories
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting ${#dirs_to_delete[@]} iOS Simulator cache location(s)..." >&2
            fi

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
            if [[ "$QUIET" != "true" ]] && [[ $deleted -gt 0 ]]; then
                echo "  ✓ iOS Simulator cache cleaned ($size_formatted)" >&2
            fi
            [[ $failed -gt 0 ]] && log_warn "$failed locations could not be deleted"
            return 0
            ;;
        xcode_archives)
            if ! is_macos; then
                log_warn "Xcode Archives cleanup is only available on macOS"
                return 1
            fi

            log_info "Cleaning Xcode Archives..."

            local path="$(get_user_home)/Library/Developer/Xcode/Archives"

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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting Xcode Archives ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Xcode Archives..." >&2
            fi

            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Xcode Archives"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Xcode Archives cleaned ($size_formatted)" >&2
                fi
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

            local path="$(get_user_home)/Library/Developer/Xcode/iOS DeviceSupport"

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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting Xcode Device Support ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Xcode Device Support..." >&2
            fi

            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Xcode Device Support"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Xcode Device Support cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Xcode Device Support"
                return 1
            fi

            return 0
            ;;
        node_modules)
            # Find all node_modules directories (not just files)
            local node_modules_dirs=()
            local search_paths=("$(get_user_home)/dev" "$(get_user_home)/projects" "$(get_user_home)/workspace" "$(get_user_home)/code" "$(get_user_home)/Documents" "$(get_user_home)/Desktop")

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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting $dir_count node_modules directories ($size_formatted)"
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to remove Docker volumes (unused volumes will be removed)"
                print_info "Volumes found: $(echo "$volumes" | wc -l | tr -d ' ')"
                if ! confirm "Remove unused Docker volumes? (y/N)" "N"; then
                    return 1
                fi
            else
                log_info "Removing unused Docker volumes ($(echo "$volumes" | wc -l | tr -d ' ') found)"
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
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
            else
                log_info "Deleting ${#orphaned_dirs[@]} orphaned application configurations ($size_formatted)"
            fi

            # Delete Application Support directories
            local deleted=0
            local failed=0
            local app_support="$(get_user_home)/Library/Application Support"
            local preferences="$(get_user_home)/Library/Preferences"

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
        npm_cache)
            log_info "Cleaning npm cache..."

            local cache_path="$(get_user_home)/.npm"

            if [[ ! -e "$cache_path" ]]; then
                log_info "No npm cache found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete npm cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete npm cache:"
                print_warning "  - Downloaded packages will be removed"
                print_warning "  - They will be re-downloaded on next npm install"
                print_warning ""

                if ! confirm "Delete npm cache? (y/N)" "N"; then
                    log_info "User cancelled npm cache deletion"
                    return 1
                fi
            else
                log_info "Deleting npm cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting npm cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted npm cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ NPM cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete npm cache"
                return 1
            fi

            return 0
            ;;
        expo_cache)
            log_info "Cleaning Expo cache..."

            local cache_path="$(get_user_home)/.expo"

            if [[ ! -e "$cache_path" ]]; then
                log_info "No Expo cache found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Expo cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete Expo cache:"
                print_warning "  - Build caches and temporary files"
                print_warning "  - They will be regenerated on next Expo build"
                print_warning ""

                if ! confirm "Delete Expo cache? (y/N)" "N"; then
                    log_info "User cancelled Expo cache deletion"
                    return 1
                fi
            else
                log_info "Deleting Expo cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Expo cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Expo cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Expo cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Expo cache"
                return 1
            fi

            return 0
            ;;
        vscode_cache)
            log_info "Cleaning VS Code cache..."

            local cache_paths=()
            if is_macos; then
                cache_paths=(
                    "$(get_user_home)/Library/Application Support/Code/Cache"
                    "$(get_user_home)/Library/Application Support/Code/CachedData"
                    "$(get_user_home)/Library/Application Support/Code/CachedExtensions"
                    "$(get_user_home)/Library/Application Support/Code/logs"
                )
            else
                cache_paths=(
                    "$(get_user_home)/.config/Code/Cache"
                    "$(get_user_home)/.config/Code/CachedData"
                    "$(get_user_home)/.config/Code/CachedExtensions"
                    "$(get_user_home)/.config/Code/logs"
                )
            fi

            # Calculate total size
            local total_size=0
            local dirs_to_delete=()
            for cache_path in "${cache_paths[@]}"; do
                if [[ -e "$cache_path" ]]; then
                    dirs_to_delete+=("$cache_path")
                    if command -v du >/dev/null 2>&1; then
                        local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                        if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + dir_size * 1024))
                        fi
                    fi
                fi
            done

            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then
                log_info "No VS Code cache found"
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete VS Code cache"
                print_info "Locations: ${#dirs_to_delete[@]} directories"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete VS Code cache:"
                print_warning "  - Extension cache and cached data"
                print_warning "  - Log files"
                print_warning "  - Settings and extensions will NOT be deleted"
                print_warning ""

                if ! confirm "Delete VS Code cache? (y/N)" "N"; then
                    log_info "User cancelled VS Code cache deletion"
                    return 1
                fi
            else
                log_info "Deleting VS Code cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting ${#dirs_to_delete[@]} VS Code cache location(s)..." >&2
            fi

            local deleted=0
            local failed=0
            for dir in "${dirs_to_delete[@]}"; do
                if rm -rf "$dir" 2>/dev/null; then
                    deleted=$((deleted + 1))
                    log_debug "Deleted: $dir"
                else
                    failed=$((failed + 1))
                    log_warn "Failed to delete: $dir"
                fi
            done

            log_success "Deleted $deleted VS Code cache locations"
            if [[ "$QUIET" != "true" ]]; then
                echo "  ✓ VS Code cache cleaned ($size_formatted)" >&2
            fi
            [[ $failed -gt 0 ]] && log_warn "$failed locations could not be deleted"
            return 0
            ;;
        nvm_cache)
            log_info "Cleaning NVM cache..."

            local cache_path="$(get_user_home)/.nvm"

            if [[ ! -e "$cache_path" ]]; then
                log_info "No NVM installation found"
                return 0
            fi

            # Only clean cache directories, not the entire .nvm (which contains installed versions)
            local cache_dirs=(
                "$(get_user_home)/.nvm/.cache"
            )

            # Calculate total size
            local total_size=0
            local dirs_to_delete=()
            for cache_dir in "${cache_dirs[@]}"; do
                if [[ -e "$cache_dir" ]]; then
                    dirs_to_delete+=("$cache_dir")
                    if command -v du >/dev/null 2>&1; then
                        local dir_size=$(du -sk "$cache_dir" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                        if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + dir_size * 1024))
                        fi
                    fi
                fi
            done

            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then
                log_info "No NVM cache found"
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete NVM cache"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete NVM cache:"
                print_warning "  - Only cache files will be deleted"
                print_warning "  - Installed Node.js versions will NOT be deleted"
                print_warning ""

                if ! confirm "Delete NVM cache? (y/N)" "N"; then
                    log_info "User cancelled NVM cache deletion"
                    return 1
                fi
            else
                log_info "Deleting NVM cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting NVM cache..." >&2
            fi

            local deleted=0
            local failed=0
            for dir in "${dirs_to_delete[@]}"; do
                if rm -rf "$dir" 2>/dev/null; then
                    deleted=$((deleted + 1))
                    log_debug "Deleted: $dir"
                else
                    failed=$((failed + 1))
                    log_warn "Failed to delete: $dir"
                fi
            done

            log_success "Deleted $deleted NVM cache locations"
            if [[ "$QUIET" != "true" ]] && [[ $deleted -gt 0 ]]; then
                echo "  ✓ NVM cache cleaned ($size_formatted)" >&2
            fi
            [[ $failed -gt 0 ]] && log_warn "$failed locations could not be deleted"
            return 0
            ;;
        cocoapods_cache)
            if ! is_macos; then
                log_warn "CocoaPods cache cleanup is only available on macOS"
                return 1
            fi

            log_info "Cleaning CocoaPods cache..."

            local cache_path="$(get_user_home)/.cocoapods"

            if [[ ! -e "$cache_path" ]]; then
                log_info "No CocoaPods cache found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete CocoaPods cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete CocoaPods cache:"
                print_warning "  - Downloaded pods will be removed"
                print_warning "  - They will be re-downloaded on next pod install"
                print_warning ""

                if ! confirm "Delete CocoaPods cache? (y/N)" "N"; then
                    log_info "User cancelled CocoaPods cache deletion"
                    return 1
                fi
            else
                log_info "Deleting CocoaPods cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting CocoaPods cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted CocoaPods cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ CocoaPods cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete CocoaPods cache"
                return 1
            fi

            return 0
            ;;
        yarn_cache)
            log_info "Cleaning Yarn cache..."

            local cache_path="$(get_user_home)/.yarn/cache"

            if [[ ! -e "$cache_path" ]]; then
                log_info "No Yarn cache found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Yarn cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete Yarn cache:"
                print_warning "  - Downloaded packages will be removed"
                print_warning "  - They will be re-downloaded on next yarn install"
                print_warning ""

                if ! confirm "Delete Yarn cache? (y/N)" "N"; then
                    log_info "User cancelled Yarn cache deletion"
                    return 1
                fi
            else
                log_info "Deleting Yarn cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Yarn cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Yarn cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Yarn cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Yarn cache"
                return 1
            fi

            return 0
            ;;
        pip_cache)
            log_info "Cleaning pip cache..."

            local cache_path=""
            if is_macos; then
                cache_path="$(get_user_home)/Library/Caches/pip"
            else
                cache_path="$(get_user_home)/.cache/pip"
            fi

            if [[ ! -e "$cache_path" ]]; then
                log_info "No pip cache found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete pip cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete pip cache:"
                print_warning "  - Downloaded Python packages will be removed"
                print_warning "  - They will be re-downloaded on next pip install"
                print_warning ""

                if ! confirm "Delete pip cache? (y/N)" "N"; then
                    log_info "User cancelled pip cache deletion"
                    return 1
                fi
            else
                log_info "Deleting pip cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting pip cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted pip cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Pip cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete pip cache"
                return 1
            fi

            return 0
            ;;
        gem_cache)
            log_info "Cleaning Ruby gem cache..."

            local cache_path="$(get_user_home)/.gem/cache"

            if [[ ! -e "$cache_path" ]]; then
                log_info "No Ruby gem cache found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Ruby gem cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete Ruby gem cache:"
                print_warning "  - Downloaded gems will be removed"
                print_warning "  - They will be re-downloaded on next gem install"
                print_warning ""

                if ! confirm "Delete Ruby gem cache? (y/N)" "N"; then
                    log_info "User cancelled Ruby gem cache deletion"
                    return 1
                fi
            else
                log_info "Deleting Ruby gem cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Ruby gem cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Ruby gem cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Ruby gem cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Ruby gem cache"
                return 1
            fi

            return 0
            ;;
        homebrew_cache)
            if ! is_macos; then
                log_warn "Homebrew cache cleanup is only available on macOS"
                return 1
            fi

            log_info "Cleaning Homebrew cache..."

            local cache_path=""
            if command -v brew >/dev/null 2>&1; then
                cache_path=$(brew --cache 2>/dev/null || echo "")
            fi

            if [[ -z "$cache_path" ]]; then
                cache_path="$(get_user_home)/Library/Caches/Homebrew"
            fi

            if [[ ! -e "$cache_path" ]]; then
                log_info "No Homebrew cache found"
                return 0
            fi

            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Homebrew cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete Homebrew cache:"
                print_warning "  - Downloaded packages will be removed"
                print_warning "  - They will be re-downloaded on next brew install"
                print_warning ""

                if ! confirm "Delete Homebrew cache? (y/N)" "N"; then
                    log_info "User cancelled Homebrew cache deletion"
                    return 1
                fi
            else
                log_info "Deleting Homebrew cache ($size_formatted)"
            fi

            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Homebrew cache..." >&2
            fi

            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Homebrew cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Homebrew cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Homebrew cache"
                return 1
            fi

            return 0
            ;;
        # Android Studio App removal (AGGRESSIVE MODE ONLY)
        android_studio_app)
            if ! is_aggressive_mode; then
                log_warn "android_studio_app cleanup requires aggressive mode"
                return 1
            fi
            
            if ! is_macos; then
                return 1
            fi
            
            log_info "Removing Android Studio.app..."
            
            local app_path="/Applications/Android Studio.app"
            
            if [[ ! -e "$app_path" ]]; then
                log_info "Android Studio.app not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$app_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            # Backup disabled by default
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "⚠ CRITICAL: About to DELETE Android Studio.app"
                print_info "Location: $app_path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "This will PERMANENTLY DELETE Android Studio!"
                print_warning ""
                
                if ! confirm "DELETE Android Studio.app? (type 'DELETE' to confirm)" "N"; then
                    log_info "User cancelled Android Studio.app deletion"
                    return 1
                fi
            else
                log_info "Deleting Android Studio.app ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Android Studio.app..." >&2
            fi
            
            if sudo rm -rf "$app_path" 2>/dev/null; then
                log_success "Deleted Android Studio.app"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Android Studio.app removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Android Studio.app (may require sudo)"
                return 1
            fi
            
            return 0
            ;;
        android_library)
            log_info "Cleaning Android Library directory..."
            
            local path="$(get_user_home)/Library/Android"
            
            if [[ ! -e "$path" ]]; then
                log_info "Android Library directory not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Android Library directory"
                print_info "Location: $path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This may contain Android SDKs"
                print_warning ""
                
                if ! confirm "Delete Android Library directory? (y/N)" "N"; then
                    log_info "User cancelled Android Library deletion"
                    return 1
                fi
            else
                log_info "Deleting Android Library directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Android Library directory..." >&2
            fi
            
            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Android Library directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Android Library directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Android Library directory"
                return 1
            fi
            
            return 0
            ;;
        android_application_support)
            log_info "Cleaning Android Studio Application Support..."
            
            local base_path="$(get_user_home)/Library/Application Support/Google"
            local paths_to_delete=()
            
            # Find AndroidStudio* directories
            while IFS= read -r dir; do
                [[ -n "$dir" ]] && [[ -d "$dir" ]] && paths_to_delete+=("$dir")
            done < <(find "$base_path" -maxdepth 1 -name "AndroidStudio*" -type d 2>/dev/null)
            
            if [[ ${#paths_to_delete[@]} -eq 0 ]]; then
                log_info "No Android Studio Application Support found"
                return 0
            fi
            
            # Calculate total size
            local total_size=0
            for path in "${paths_to_delete[@]}"; do
                if command -v du >/dev/null 2>&1; then
                    local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Android Studio Application Support"
                print_info "Found ${#paths_to_delete[@]} directory(ies)"
                print_info "Total size: $size_formatted"
                print_warning ""
                
                if ! confirm "Delete Android Studio Application Support? (y/N)" "N"; then
                    log_info "User cancelled Android Studio Application Support deletion"
                    return 1
                fi
            else
                log_info "Deleting Android Studio Application Support ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting ${#paths_to_delete[@]} Android Studio Application Support directory(ies)..." >&2
            fi
            
            local deleted=0
            local failed=0
            for path in "${paths_to_delete[@]}"; do
                if rm -rf "$path" 2>/dev/null; then
                    deleted=$((deleted + 1))
                else
                    failed=$((failed + 1))
                fi
            done
            
            log_success "Deleted $deleted Android Studio Application Support directory(ies)"
            if [[ "$QUIET" != "true" ]] && [[ $deleted -gt 0 ]]; then
                echo "  ✓ Android Studio Application Support removed ($size_formatted)" >&2
            fi
            [[ $failed -gt 0 ]] && log_warn "$failed directory(ies) could not be deleted"
            return 0
            ;;
        # Application Support heavy categories
        application_support_google)
            log_info "Cleaning Google Application Support..."
            
            local path="$(get_user_home)/Library/Application Support/Google"
            
            if [[ ! -e "$path" ]]; then
                log_info "Google Application Support not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Google Application Support"
                print_info "Location: $path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This may contain Chrome/Drive data"
                print_warning ""
                
                if ! confirm "Delete Google Application Support? (y/N)" "N"; then
                    log_info "User cancelled Google Application Support deletion"
                    return 1
                fi
            else
                log_info "Deleting Google Application Support ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Google Application Support..." >&2
            fi
            
            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Google Application Support"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Google Application Support removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Google Application Support"
                return 1
            fi
            
            return 0
            ;;
        application_support_cursor)
            log_info "Cleaning Cursor Application Support..."
            
            local path="$(get_user_home)/Library/Application Support/Cursor"
            
            if [[ ! -e "$path" ]]; then
                log_info "Cursor Application Support not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Cursor Application Support"
                print_info "Location: $path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This may contain Cursor settings/extensions"
                print_warning ""
                
                if ! confirm "Delete Cursor Application Support? (y/N)" "N"; then
                    log_info "User cancelled Cursor Application Support deletion"
                    return 1
                fi
            else
                log_info "Deleting Cursor Application Support ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Cursor Application Support..." >&2
            fi
            
            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Cursor Application Support"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Cursor Application Support removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Cursor Application Support"
                return 1
            fi
            
            return 0
            ;;
        application_support_wallpaper)
            log_info "Cleaning macOS Wallpaper Application Support..."
            
            local path="$(get_user_home)/Library/Application Support/com.apple.wallpaper"
            
            if [[ ! -e "$path" ]]; then
                log_info "Wallpaper Application Support not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete macOS Wallpaper Application Support"
                print_info "Location: $path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: Wallpapers can be re-downloaded"
                print_warning ""
                
                if ! confirm "Delete Wallpaper Application Support? (y/N)" "N"; then
                    log_info "User cancelled Wallpaper Application Support deletion"
                    return 1
                fi
            else
                log_info "Deleting Wallpaper Application Support ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Wallpaper Application Support..." >&2
            fi
            
            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Wallpaper Application Support"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Wallpaper Application Support removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Wallpaper Application Support"
                return 1
            fi
            
            return 0
            ;;
        # Containers cleanup
        containers_cleanup)
            log_info "Cleaning orphaned Containers..."
            
            local containers_dir="$(get_user_home)/Library/Containers"
            
            if [[ ! -d "$containers_dir" ]]; then
                log_info "Containers directory not found"
                return 0
            fi
            
            # Find containers for deleted apps
            local orphaned_containers=()
            while IFS= read -r container; do
                [[ -z "$container" ]] || [[ ! -d "$container" ]] && continue
                
                local bundle_id=$(basename "$container")
                
                # Check if app still exists
                local app_found=false
                if [[ -d "/Applications/${bundle_id}.app" ]]; then
                    app_found=true
                else
                    # Check by bundle ID pattern
                    while IFS= read -r app_path; do
                        if [[ -f "${app_path}/Contents/Info.plist" ]]; then
                            local app_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${app_path}/Contents/Info.plist" 2>/dev/null)
                            if [[ "$app_bundle_id" == "$bundle_id" ]]; then
                                app_found=true
                                break
                            fi
                        fi
                    done < <(find /Applications -maxdepth 2 -name "*.app" -type d 2>/dev/null)
                fi
                
                if [[ "$app_found" == "false" ]]; then
                    orphaned_containers+=("$container")
                fi
            done < <(find "$containers_dir" -maxdepth 1 -type d ! -path "$containers_dir" 2>/dev/null)
            
            if [[ ${#orphaned_containers[@]} -eq 0 ]]; then
                log_info "No orphaned containers found"
                return 0
            fi
            
            # Calculate total size
            local total_size=0
            for container in "${orphaned_containers[@]}"; do
                if command -v du >/dev/null 2>&1; then
                    local dir_size=$(du -sk "$container" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "Found ${#orphaned_containers[@]} orphaned container(s):"
                for container in "${orphaned_containers[@]}"; do
                    local bundle_id=$(basename "$container")
                    local container_size=$(du -sh "$container" 2>/dev/null | awk '{print $1}' || echo "unknown")
                    print_info "  - $bundle_id ($container_size)"
                done
                print_info ""
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: These are containers for deleted apps"
                print_warning ""
                
                if ! confirm "Delete orphaned containers? (y/N)" "N"; then
                    log_info "User cancelled containers cleanup"
                    return 1
                fi
            else
                log_info "Deleting ${#orphaned_containers[@]} orphaned container(s) ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting ${#orphaned_containers[@]} orphaned container(s)..." >&2
            fi
            
            local deleted=0
            local failed=0
            for container in "${orphaned_containers[@]}"; do
                if rm -rf "$container" 2>/dev/null; then
                    deleted=$((deleted + 1))
                    log_debug "Deleted: $container"
                else
                    failed=$((failed + 1))
                    log_warn "Failed to delete: $container"
                fi
            done
            
            log_success "Deleted $deleted orphaned container(s)"
            if [[ "$QUIET" != "true" ]] && [[ $deleted -gt 0 ]]; then
                echo "  ✓ Orphaned containers removed ($size_formatted)" >&2
            fi
            [[ $failed -gt 0 ]] && log_warn "$failed container(s) could not be deleted"
            return 0
            ;;
        # .NET categories
        nuget_cache)
            log_info "Cleaning NuGet cache..."
            
            local cache_path="$(get_user_home)/.nuget"
            
            if [[ ! -e "$cache_path" ]]; then
                log_info "No NuGet cache found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete NuGet cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete NuGet packages cache"
                print_warning "  - They will be re-downloaded on next restore"
                print_warning ""
                
                if ! confirm "Delete NuGet cache? (y/N)" "N"; then
                    log_info "User cancelled NuGet cache deletion"
                    return 1
                fi
            else
                log_info "Deleting NuGet cache ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting NuGet cache..." >&2
            fi
            
            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted NuGet cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ NuGet cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete NuGet cache"
                return 1
            fi
            
            return 0
            ;;
        dotnet_cache)
            log_info "Cleaning .NET cache..."
            
            local cache_path="$(get_user_home)/.dotnet"
            
            if [[ ! -e "$cache_path" ]]; then
                log_info "No .NET cache found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete .NET cache"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete .NET SDK cache"
                print_warning "  - They will be re-downloaded on next use"
                print_warning ""
                
                if ! confirm "Delete .NET cache? (y/N)" "N"; then
                    log_info "User cancelled .NET cache deletion"
                    return 1
                fi
            else
                log_info "Deleting .NET cache ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting .NET cache..." >&2
            fi
            
            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted .NET cache"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ .NET cache cleaned ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete .NET cache"
                return 1
            fi
            
            return 0
            ;;
        # Homebrew cleanup
        homebrew_cleanup)
            if ! is_macos; then
                log_warn "Homebrew cleanup is only available on macOS"
                return 1
            fi
            
            if ! command -v brew >/dev/null 2>&1; then
                log_warn "Homebrew not found"
                return 1
            fi
            
            log_info "Running Homebrew cleanup..."
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to run: brew cleanup -s"
                print_warning ""
                print_warning "⚠ WARNING: This will remove old Homebrew downloads"
                print_warning ""
                
                if ! confirm "Run brew cleanup? (y/N)" "N"; then
                    log_info "User cancelled Homebrew cleanup"
                    return 1
                fi
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Running brew cleanup -s..." >&2
            fi
            
            # Run brew cleanup -s
            if brew cleanup -s 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                log_success "Homebrew cleanup completed"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Homebrew cleanup completed" >&2
                fi
            else
                log_warn "Homebrew cleanup failed"
                return 1
            fi
            
            # Optional: Find unused formulas (aggressive mode only)
            if is_aggressive_mode; then
                log_info "Finding unused Homebrew formulas..."
                
                if command -v brew >/dev/null 2>&1; then
                    local unused_formulas=$(brew leaves 2>/dev/null | while read formula; do
                        brew uses --installed "$formula" 2>/dev/null | grep -q . || echo "$formula"
                    done)
                    
                    if [[ -n "$unused_formulas" ]]; then
                        print_warning "Found potentially unused formulas:"
                        echo "$unused_formulas" | while read formula; do
                            print_info "  - $formula"
                        done
                        print_warning ""
                        
                        if ! confirm "Remove unused formulas? (y/N)" "N"; then
                            log_info "User skipped unused formulas removal"
                        else
                            echo "$unused_formulas" | while read formula; do
                                brew uninstall "$formula" 2>/dev/null && log_debug "Uninstalled: $formula"
                            done
                        fi
                    fi
                fi
            fi
            
            return 0
            ;;
        # Aggressive language environments
        gradle_full)
            if ! is_aggressive_mode; then
                log_warn "gradle_full cleanup requires aggressive mode"
                return 1
            fi
            
            log_info "Cleaning Gradle directory (full)..."
            
            local cache_path="$(get_user_home)/.gradle"
            
            if [[ ! -e "$cache_path" ]]; then
                log_info "No Gradle directory found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete entire Gradle directory"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete ALL Gradle data:"
                print_warning "  - Caches, wrapper, daemon, etc."
                print_warning ""
                
                if ! confirm "Delete Gradle directory? (y/N)" "N"; then
                    log_info "User cancelled Gradle directory deletion"
                    return 1
                fi
            else
                log_info "Deleting Gradle directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Gradle directory..." >&2
            fi
            
            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Gradle directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Gradle directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Gradle directory"
                return 1
            fi
            
            return 0
            ;;
        yarn_full)
            if ! is_aggressive_mode; then
                log_warn "yarn_full cleanup requires aggressive mode"
                return 1
            fi
            
            log_info "Cleaning Yarn directory (full)..."
            
            local cache_path="$(get_user_home)/.yarn"
            
            if [[ ! -e "$cache_path" ]]; then
                log_info "No Yarn directory found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete entire Yarn directory"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete ALL Yarn data"
                print_warning ""
                
                if ! confirm "Delete Yarn directory? (y/N)" "N"; then
                    log_info "User cancelled Yarn directory deletion"
                    return 1
                fi
            else
                log_info "Deleting Yarn directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Yarn directory..." >&2
            fi
            
            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Yarn directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Yarn directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Yarn directory"
                return 1
            fi
            
            return 0
            ;;
        nvm_full)
            if ! is_aggressive_mode; then
                log_warn "nvm_full cleanup requires aggressive mode"
                return 1
            fi
            
            log_info "Cleaning NVM directory (full - removes all Node.js versions)..."
            
            local cache_path="$(get_user_home)/.nvm"
            
            if [[ ! -e "$cache_path" ]]; then
                log_info "No NVM directory found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "⚠ CRITICAL: About to delete entire NVM directory"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete ALL Node.js versions!"
                print_warning "  - All installed Node.js versions will be removed"
                print_warning "  - You will need to reinstall Node.js versions"
                print_warning ""
                
                if ! confirm "DELETE NVM directory? (type 'DELETE' to confirm)" "N"; then
                    log_info "User cancelled NVM directory deletion"
                    return 1
                fi
            else
                log_info "Deleting NVM directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting NVM directory..." >&2
            fi
            
            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted NVM directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ NVM directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete NVM directory"
                return 1
            fi
            
            return 0
            ;;
        docker_full)
            if ! is_aggressive_mode; then
                log_warn "docker_full cleanup requires aggressive mode"
                return 1
            fi
            
            log_info "Cleaning Docker directory (full)..."
            
            local cache_path="$(get_user_home)/.docker"
            
            if [[ ! -e "$cache_path" ]]; then
                log_info "No Docker directory found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$cache_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete entire Docker directory"
                print_info "Location: $cache_path"
                print_info "Total size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete ALL Docker data"
                print_warning ""
                
                if ! confirm "Delete Docker directory? (y/N)" "N"; then
                    log_info "User cancelled Docker directory deletion"
                    return 1
                fi
            else
                log_info "Deleting Docker directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Docker directory..." >&2
            fi
            
            if rm -rf "$cache_path" 2>/dev/null; then
                log_success "Deleted Docker directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Docker directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Docker directory"
                return 1
            fi
            
            return 0
            ;;
        # Large directories and dev
        large_directories)
            log_info "Finding large directories (>1GB)..."
            
            local threshold_gb="${LARGE_DIR_THRESHOLD:-1}"
            local threshold_bytes=$((threshold_gb * 1024 * 1024 * 1024))
            local large_dirs=()
            
            # Find large directories in home
            while IFS= read -r dir; do
                [[ -z "$dir" ]] || [[ ! -d "$dir" ]] && continue
                
                # Skip protected directories
                local basename_dir=$(basename "$dir")
                if [[ "$basename_dir" == ".git" ]] || \
                   [[ "$basename_dir" == ".claude" ]] || \
                   [[ "$basename_dir" == ".cursor" ]] || \
                   [[ "$basename_dir" == ".task-flow" ]] || \
                   [[ "$basename_dir" == ".ssh" ]] || \
                   [[ "$basename_dir" == ".gnupg" ]]; then
                    continue
                fi
                
                local dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    local dir_size_bytes=$((dir_size * 1024))
                    if [[ $dir_size_bytes -ge $threshold_bytes ]]; then
                        large_dirs+=("$dir|$dir_size_bytes")
                    fi
                fi
            done < <(find "$(get_user_home)" -maxdepth 2 -type d ! -path "*/\.*" 2>/dev/null)
            
            if [[ ${#large_dirs[@]} -eq 0 ]]; then
                log_info "No large directories found (>${threshold_gb}GB)"
                return 0
            fi
            
            # Show list
            print_warning "Found ${#large_dirs[@]} large directory(ies) (>${threshold_gb}GB):"
            for dir_info in "${large_dirs[@]}"; do
                IFS='|' read -r dir size_bytes <<< "$dir_info"
                local size_mb=$((size_bytes / 1024 / 1024))
                local size_display=""
                if [[ $size_mb -ge 1024 ]]; then
                    local size_gb=$(awk "BEGIN {printf \"%.2f\", $size_bytes / 1073741824}")
                    size_display="${size_gb} GB"
                else
                    size_display="${size_mb} MB"
                fi
                print_info "  - $dir ($size_display)"
            done
            print_warning ""
            
            if ! confirm "Delete these large directories? (y/N)" "N"; then
                log_info "User cancelled large directories deletion"
                return 1
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting ${#large_dirs[@]} large directory(ies)..." >&2
            fi
            
            local deleted=0
            local failed=0
            for dir_info in "${large_dirs[@]}"; do
                IFS='|' read -r dir size_bytes <<< "$dir_info"
                
                # Backup disabled by default
                
                if rm -rf "$dir" 2>/dev/null; then
                    deleted=$((deleted + 1))
                    log_debug "Deleted: $dir"
                else
                    failed=$((failed + 1))
                    log_warn "Failed to delete: $dir"
                fi
            done
            
            log_success "Deleted $deleted large directory(ies)"
            if [[ "$QUIET" != "true" ]] && [[ $deleted -gt 0 ]]; then
                echo "  ✓ Large directories removed" >&2
            fi
            [[ $failed -gt 0 ]] && log_warn "$failed directory(ies) could not be deleted"
            return 0
            ;;
        dev_directory)
            if ! is_aggressive_mode; then
                log_warn "dev_directory cleanup requires aggressive mode"
                return 1
            fi
            
            log_info "Removing dev directory..."
            
            local dev_path="$(get_user_home)/dev"
            
            if [[ ! -e "$dev_path" ]]; then
                log_info "dev directory not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$dev_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            # Backup disabled by default
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "⚠ CRITICAL: About to DELETE dev directory"
                print_info "Location: $dev_path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will DELETE ALL your development projects!"
                print_warning "  - All code projects will be permanently deleted"
                print_warning "  - Make sure you have backups/commits"
                print_warning ""
                
                if ! confirm "DELETE dev directory? (type 'DELETE' to confirm)" "N"; then
                    log_info "User cancelled dev directory deletion"
                    return 1
                fi
            else
                log_info "Deleting dev directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting dev directory..." >&2
            fi
            
            if rm -rf "$dev_path" 2>/dev/null; then
                log_success "Deleted dev directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ dev directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete dev directory"
                return 1
            fi
            
            return 0
            ;;
        # Xcode App removal (AGGRESSIVE MODE ONLY) - moved here to avoid duplicate
        xcode_app)
            if ! is_aggressive_mode; then
                log_warn "xcode_app cleanup requires aggressive mode"
                return 1
            fi
            
            if ! is_macos; then
                log_warn "Xcode app cleanup is only available on macOS"
                return 1
            fi
            
            log_info "Removing Xcode.app..."
            
            local app_path="/Applications/Xcode.app"
            
            if [[ ! -e "$app_path" ]]; then
                log_info "Xcode.app not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$app_path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            # Backup disabled by default
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "⚠ CRITICAL: About to DELETE Xcode.app"
                print_info "Location: $app_path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "This will PERMANENTLY DELETE Xcode from your system!"
                print_warning "You will need to reinstall from App Store if needed."
                print_warning ""
                
                if ! confirm "DELETE Xcode.app? (type 'DELETE' to confirm)" "N"; then
                    log_info "User cancelled Xcode.app deletion"
                    return 1
                fi
            else
                log_info "Deleting Xcode.app ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Xcode.app..." >&2
            fi
            
            if sudo rm -rf "$app_path" 2>/dev/null; then
                log_success "Deleted Xcode.app"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Xcode.app removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Xcode.app (may require sudo)"
                return 1
            fi
            
            return 0
            ;;
        xcode_developer_full)
            if ! is_aggressive_mode; then
                log_warn "xcode_developer_full cleanup requires aggressive mode"
                return 1
            fi
            
            if ! is_macos; then
                return 1
            fi
            
            log_info "Removing Xcode Developer directory..."
            
            local path="$(get_user_home)/Library/Developer/Xcode"
            
            if [[ ! -e "$path" ]]; then
                log_info "Xcode Developer directory not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            # Backup disabled by default
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete entire Xcode Developer directory"
                print_info "Location: $path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This includes ALL Xcode data:"
                print_warning "  - DerivedData, Archives, DeviceSupport"
                print_warning "  - All Xcode configurations"
                print_warning ""
                
                if ! confirm "Delete Xcode Developer directory? (y/N)" "N"; then
                    log_info "User cancelled Xcode Developer directory deletion"
                    return 1
                fi
            else
                log_info "Deleting Xcode Developer directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Xcode Developer directory..." >&2
            fi
            
            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Xcode Developer directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Xcode Developer directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Xcode Developer directory"
                return 1
            fi
            
            return 0
            ;;
        xcode_simulator_full)
            if ! is_aggressive_mode; then
                log_warn "xcode_simulator_full cleanup requires aggressive mode"
                return 1
            fi
            
            if ! is_macos; then
                return 1
            fi
            
            log_info "Removing CoreSimulator directory..."
            
            local path="$(get_user_home)/Library/Developer/CoreSimulator"
            
            if [[ ! -e "$path" ]]; then
                log_info "CoreSimulator directory not found"
                return 0
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete CoreSimulator directory"
                print_info "Location: $path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will delete ALL iOS Simulator data"
                print_warning ""
                
                if ! confirm "Delete CoreSimulator directory? (y/N)" "N"; then
                    log_info "User cancelled CoreSimulator directory deletion"
                    return 1
                fi
            else
                log_info "Deleting CoreSimulator directory ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting CoreSimulator directory..." >&2
            fi
            
            if rm -rf "$path" 2>/dev/null; then
                log_success "Deleted CoreSimulator directory"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ CoreSimulator directory removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete CoreSimulator directory"
                return 1
            fi
            
            return 0
            ;;
        xcode_command_line_tools)
            if ! is_aggressive_mode; then
                log_warn "xcode_command_line_tools cleanup requires aggressive mode"
                return 1
            fi
            
            if ! is_macos; then
                return 1
            fi
            
            log_info "Removing Command Line Tools..."
            
            local path="/Library/Developer/CommandLineTools"
            
            if [[ ! -e "$path" ]]; then
                log_info "Command Line Tools not found"
                return 0
            fi
            
            # Check sudo
            if ! sudo -n true 2>/dev/null; then
                log_warn "Command Line Tools removal requires sudo"
                return 1
            fi
            
            # Calculate size
            local total_size=0
            if command -v du >/dev/null 2>&1; then
                local dir_size=$(sudo du -sk "$path" 2>/dev/null | awk '{print $1}' | head -1 | tr -d '[:space:]')
                if [[ -n "$dir_size" ]] && [[ "$dir_size" =~ ^[0-9]+$ ]]; then
                    total_size=$(awk "BEGIN {printf \"%.0f\", $dir_size * 1024}" 2>/dev/null || echo "0")
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
            
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Command Line Tools"
                print_info "Location: $path"
                print_info "Size: $size_formatted"
                print_warning ""
                print_warning "⚠ WARNING: This will remove Command Line Tools"
                print_warning "  - Can be reinstalled with: xcode-select --install"
                print_warning ""
                
                if ! confirm "Delete Command Line Tools? (y/N)" "N"; then
                    log_info "User cancelled Command Line Tools deletion"
                    return 1
                fi
            else
                log_info "Deleting Command Line Tools ($size_formatted)"
            fi
            
            if [[ "$QUIET" != "true" ]]; then
                echo "  → Deleting Command Line Tools..." >&2
            fi
            
            if sudo rm -rf "$path" 2>/dev/null; then
                log_success "Deleted Command Line Tools"
                if [[ "$QUIET" != "true" ]]; then
                    echo "  ✓ Command Line Tools removed ($size_formatted)" >&2
                fi
            else
                log_warn "Failed to delete Command Line Tools"
                return 1
            fi
            
            return 0
            ;;
        flutter_cache)
            log_info "Cleaning Flutter/Dart pub cache..."
            local path="$(get_user_home)/.pub-cache"
            if [[ ! -e "$path" ]]; then log_info "Flutter cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Flutter/Dart pub cache"
                print_info "Location: $path  |  Size: $size_formatted"
                print_warning "  - Packages re-downloaded with: flutter pub get"
                if ! confirm "Delete Flutter cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Flutter cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Flutter cache" || { log_warn "Failed to delete Flutter cache"; return 1; }
            return 0
            ;;

        swiftpm_cache)
            log_info "Cleaning Swift Package Manager cache..."
            local path="$(get_user_home)/Library/Caches/org.swift.swiftpm"
            if [[ ! -e "$path" ]]; then log_info "SwiftPM cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Swift Package Manager cache"
                print_info "Location: $path  |  Size: $size_formatted"
                print_warning "  - Packages re-downloaded on next Xcode build"
                if ! confirm "Delete SwiftPM cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting SwiftPM cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted SwiftPM cache" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        xcode_sim_logs)
            log_info "Cleaning Xcode/Simulator logs..."
            local paths=("$(get_user_home)/Library/Logs/CoreSimulator" "$(get_user_home)/Library/Logs/DiagnosticReports")
            local total_size=0; local dirs_to_delete=()
            for p in "${paths[@]}"; do
                [[ ! -e "$p" ]] && continue
                dirs_to_delete+=("$p")
                local sz=$(du -sk "$p" 2>/dev/null | awk '{print $1}'); [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024))
            done
            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then log_info "No Xcode/Simulator logs found"; return 0; fi
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Xcode/Simulator logs ($size_formatted)"
                print_warning "  - Crash reports, simulator logs — only logs, no build data"
                if ! confirm "Delete Xcode/Simulator logs? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Xcode/Simulator logs ($size_formatted)"
            fi
            for p in "${dirs_to_delete[@]}"; do rm -rf "$p" 2>/dev/null && log_debug "Deleted: $p" || log_warn "Failed: $p"; done
            log_success "Deleted Xcode/Simulator logs"
            return 0
            ;;

        carthage_cache)
            log_info "Cleaning Carthage cache..."
            local path="$(get_user_home)/Library/Caches/org.carthage.CarthageKit"
            if [[ ! -e "$path" ]]; then log_info "Carthage cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Carthage cache ($size_formatted)"
                print_warning "  - Frameworks re-downloaded with: carthage update"
                if ! confirm "Delete Carthage cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Carthage cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Carthage cache" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        ruby_bundler_cache)
            log_info "Cleaning Ruby Bundler cache..."
            local path="$(get_user_home)/.bundle/cache"
            if [[ ! -e "$path" ]]; then log_info "Bundler cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Ruby Bundler cache ($size_formatted)"
                print_warning "  - Gems re-downloaded with: bundle install"
                if ! confirm "Delete Bundler cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Bundler cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Bundler cache" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        turborepo_cache)
            log_info "Cleaning Turborepo cache..."
            local path="$(get_user_home)/.turbo"
            if [[ ! -e "$path" ]]; then log_info "Turborepo cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Turborepo global cache ($size_formatted)"
                print_warning "  - Rebuilt on next: turbo build"
                if ! confirm "Delete Turborepo cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Turborepo cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Turborepo cache" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        jest_cache)
            log_info "Cleaning Jest cache..."
            local dirs_to_delete=(); local total_size=0
            while IFS= read -r d; do
                dirs_to_delete+=("$d")
                local sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}'); [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024))
            done < <(find /tmp -maxdepth 1 -name "jest-*" -type d 2>/dev/null)
            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then log_info "No Jest cache found"; return 0; fi
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete ${#dirs_to_delete[@]} Jest cache dir(s) ($size_formatted)"
                print_warning "  - Rebuilt on next test run"
                if ! confirm "Delete Jest cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Jest cache ($size_formatted)"
            fi
            for d in "${dirs_to_delete[@]}"; do rm -rf "$d" 2>/dev/null; done
            log_success "Deleted Jest cache"
            return 0
            ;;

        playwright_cache)
            log_info "Cleaning Playwright browser cache..."
            local path
            if is_macos; then path="$(get_user_home)/Library/Caches/ms-playwright"
            else path="$(get_user_home)/.cache/ms-playwright"; fi
            if [[ ! -e "$path" ]]; then log_info "Playwright cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Playwright browser cache ($size_formatted)"
                print_warning "  - Browsers re-downloaded with: npx playwright install"
                if ! confirm "Delete Playwright cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Playwright cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Playwright cache" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        cypress_cache)
            log_info "Cleaning Cypress cache..."
            local path="$(get_user_home)/.cache/Cypress"
            if [[ ! -e "$path" ]]; then log_info "Cypress cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Cypress cache ($size_formatted)"
                print_warning "  - Binary re-downloaded with: npx cypress install"
                if ! confirm "Delete Cypress cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Cypress cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Cypress cache" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        pnpm_store)
            log_info "Cleaning pnpm store..."
            local path="$(get_user_home)/.pnpm-store"
            if [[ ! -e "$path" ]]; then log_info "pnpm store not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete pnpm global store ($size_formatted)"
                print_warning "  - All pnpm projects will re-download packages on next install"
                if ! confirm "Delete pnpm store? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting pnpm store ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted pnpm store" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        bun_cache)
            log_info "Cleaning Bun cache..."
            local path="$(get_user_home)/.bun/install/cache"
            if [[ ! -e "$path" ]]; then log_info "Bun cache not found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete Bun install cache ($size_formatted)"
                print_warning "  - Packages re-downloaded with: bun install"
                if ! confirm "Delete Bun cache? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting Bun cache ($size_formatted)"
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Bun cache" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        android_project_builds)
            log_info "Cleaning Android project build outputs..."
            local search_paths=("$(get_user_home)/dev" "$(get_user_home)/projects" "$(get_user_home)/workspace" "$(get_user_home)/code")
            local dirs_to_delete=(); local total_size=0
            for base in "${search_paths[@]}"; do
                [[ ! -d "$base" ]] && continue
                while IFS= read -r d; do
                    dirs_to_delete+=("$d")
                    local sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}'); [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024))
                done < <(find "$base" -maxdepth 6 -type d -name "build" -path "*/app/build" 2>/dev/null | head -20)
            done
            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then log_info "No Android project build dirs found"; return 0; fi
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete ${#dirs_to_delete[@]} Android build dir(s) ($size_formatted)"
                print_warning "  - Rebuilt with: ./gradlew build (or cd android && ./gradlew build)"
                if ! confirm "Delete Android project builds? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting ${#dirs_to_delete[@]} Android build dir(s) ($size_formatted)"
            fi
            for d in "${dirs_to_delete[@]}"; do rm -rf "$d" 2>/dev/null && log_debug "Deleted: $d" || log_warn "Failed: $d"; done
            log_success "Deleted Android project build dirs"
            return 0
            ;;

        ios_project_builds)
            log_info "Cleaning iOS project build outputs..."
            local search_paths=("$(get_user_home)/dev" "$(get_user_home)/projects" "$(get_user_home)/workspace" "$(get_user_home)/code")
            local dirs_to_delete=(); local total_size=0
            for base in "${search_paths[@]}"; do
                [[ ! -d "$base" ]] && continue
                while IFS= read -r d; do
                    dirs_to_delete+=("$d")
                    local sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}'); [[ "$sz" =~ ^[0-9]+$ ]] && total_size=$((total_size + sz * 1024))
                done < <(find "$base" -maxdepth 6 -type d \( -path "*/ios/build" -o -path "*/Build/Products" \) 2>/dev/null | head -20)
            done
            if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then log_info "No iOS project build dirs found"; return 0; fi
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to delete ${#dirs_to_delete[@]} iOS build dir(s) ($size_formatted)"
                print_warning "  - Rebuilt via Xcode or: npx react-native run-ios"
                if ! confirm "Delete iOS project builds? (y/N)" "N"; then return 1; fi
            else
                log_info "Deleting ${#dirs_to_delete[@]} iOS build dir(s) ($size_formatted)"
            fi
            for d in "${dirs_to_delete[@]}"; do rm -rf "$d" 2>/dev/null && log_debug "Deleted: $d" || log_warn "Failed: $d"; done
            log_success "Deleted iOS project build dirs"
            return 0
            ;;

        android_avd)
            # HIGH RISK — always confirm, even in force/skip mode
            log_info "Android AVD deletion requested..."
            local path="$(get_user_home)/.android/avd"
            if [[ ! -e "$path" ]]; then log_info "No Android AVDs found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            print_warning ""
            print_warning "╔══════════════════════════════════════════╗"
            print_warning "║  ATENCAO: APAGAR EMULADORES ANDROID      ║"
            print_warning "╚══════════════════════════════════════════╝"
            print_warning ""
            print_warning "Isso vai apagar TODOS os AVDs (emuladores Android)."
            print_info "Tamanho: $size_formatted"
            print_warning "  - Os emuladores serao removidos permanentemente"
            print_warning "  - Precisara criar novos AVDs no Android Studio"
            print_warning "  - Dados e apps instalados nos emuladores serao perdidos"
            print_warning ""
            print_info "Use apenas se quiser comecar do zero com os emuladores."
            print_warning ""
            local response
            read -r -p "Digite 'yes' para confirmar (qualquer outra coisa cancela): " response </dev/tty
            if [[ "$response" != "yes" ]]; then
                log_info "User cancelled Android AVD deletion"
                return 1
            fi
            rm -rf "$path" 2>/dev/null && log_success "Deleted Android AVDs" || { log_warn "Failed to delete AVDs"; return 1; }
            return 0
            ;;

        android_sdk_old)
            # HIGH RISK — always confirm, even in force/skip mode
            log_info "Android SDK platforms deletion requested..."
            local base="$(get_user_home)/Library/Android/sdk/platforms"
            if [[ ! -d "$base" ]]; then log_info "No Android SDK platforms found"; return 0; fi
            local -a versions=()
            while IFS= read -r d; do versions+=("$(basename "$d")"); done < <(find "$base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
            if [[ ${#versions[@]} -eq 0 ]]; then log_info "No SDK platform versions found"; return 0; fi
            local sz=$(du -sk "$base" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            print_warning ""
            print_warning "╔══════════════════════════════════════════╗"
            print_warning "║  ATENCAO: APAGAR ANDROID SDK PLATFORMS   ║"
            print_warning "╚══════════════════════════════════════════╝"
            print_warning ""
            print_info "Versoes encontradas:"
            for v in "${versions[@]}"; do print_info "  - $v"; done
            print_warning ""
            print_warning "Tamanho total: $size_formatted"
            print_warning "  - TODOS os SDK platforms serao removidos"
            print_warning "  - Projetos que dependem de versoes especificas podem nao compilar"
            print_warning "  - Precisara reinstalar via Android Studio > SDK Manager"
            print_warning ""
            print_info "Use apenas se quiser limpar e reinstalar o SDK do zero."
            print_warning ""
            local response
            read -r -p "Digite 'yes' para confirmar (qualquer outra coisa cancela): " response </dev/tty
            if [[ "$response" != "yes" ]]; then
                log_info "User cancelled Android SDK platforms deletion"
                return 1
            fi
            rm -rf "$base" 2>/dev/null && log_success "Deleted Android SDK platforms" || { log_warn "Failed"; return 1; }
            return 0
            ;;

        ios_simulator_devices)
            # HIGH RISK — always confirm, even in force/skip mode
            if ! is_macos; then return 0; fi
            log_info "iOS Simulator Devices deletion requested..."
            local path="$(get_user_home)/Library/Developer/CoreSimulator/Devices"
            if [[ ! -e "$path" ]]; then log_info "No iOS Simulator Devices found"; return 0; fi
            local sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); [[ ! "$sz" =~ ^[0-9]+$ ]] && sz=0
            local total_size=$((sz * 1024))
            local size_formatted; size_formatted=$(awk -v b="$total_size" 'BEGIN { if(b>=1073741824) printf "%.2f GB\n",b/1073741824; else printf "%.2f MB\n",b/1048576 }')
            print_warning ""
            print_warning "╔══════════════════════════════════════════╗"
            print_warning "║  ATENCAO: APAGAR SIMULADORES iOS         ║"
            print_warning "╚══════════════════════════════════════════╝"
            print_warning ""
            print_warning "Isso vai apagar TODOS os simuladores iOS instalados."
            print_info "Tamanho: $size_formatted"
            print_warning "  - Todos os simuladores serao removidos permanentemente"
            print_warning "  - Apps instalados nos simuladores serao perdidos"
            print_warning "  - O Xcode vai recriar os simuladores padrao automaticamente"
            print_warning "  - Simuladores customizados precisarao ser recriados manualmente"
            print_warning ""
            print_info "Use apenas se quiser limpar todos os simuladores e comecar do zero."
            print_warning ""
            local response
            read -r -p "Digite 'yes' para confirmar (qualquer outra coisa cancela): " response </dev/tty
            if [[ "$response" != "yes" ]]; then
                log_info "User cancelled iOS Simulator Devices deletion"
                return 1
            fi
            if command -v xcrun >/dev/null 2>&1; then
                xcrun simctl shutdown all 2>/dev/null || true
                xcrun simctl delete all 2>/dev/null || true
            else
                rm -rf "$path" 2>/dev/null
            fi
            log_success "Deleted iOS Simulator Devices"
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

    # Special handling for browser_trash - use macOS native command for reliability
    if [[ "$category" == "browser_trash" ]]; then
        # Skip path existence check for trash - macOS protections may block access
        log_debug "Using AppleScript for trash access (path: $path)"
    elif [[ -z "$path" ]] || [[ ! -e "$path" ]]; then
        log_warn "Category $category: path not found ($path)"
        return 1
    fi

    if [[ "$category" == "browser_trash" ]]; then
        if is_macos; then
            # Determine which user's trash to access
            local target_user=""
            if [[ -n "$HOME_OVERRIDE" ]] && [[ "$HOME_OVERRIDE" != "$HOME" ]]; then
                # Multi-user mode: extract username from HOME_OVERRIDE
                target_user=$(basename "$HOME_OVERRIDE")
                log_debug "Accessing trash for user: $target_user"
            fi

            # Count items in trash using AppleScript (required for macOS privacy protections)
            local trash_count=0
            if command -v osascript >/dev/null 2>&1; then
                if [[ -n "$target_user" ]] && [[ "$target_user" != "$USER" ]]; then
                    # For other users, try to count files directly (may fail due to permissions)
                    # In multi-user mode, we can't use AppleScript for other users' trash
                    trash_count=$(sudo -u "$target_user" find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | xargs)
                else
                    # Current user: use AppleScript
                    trash_count=$(osascript -e 'tell application "Finder" to return (count of items of trash)' 2>/dev/null || echo "0")
                fi
            fi

            if [[ "$trash_count" -eq 0 ]]; then
                if [[ -n "$target_user" ]] && [[ "$target_user" != "$USER" ]]; then
                    log_info "Cannot access trash for user '$target_user' (macOS privacy protection)"
                else
                    log_info "Trash is already empty"
                fi
                return 0
            fi

            # Get trash items list for size calculation (fallback to approximation if inaccessible)
            local trash_items=()
            while IFS= read -r item; do
                [[ -n "$item" ]] && trash_items+=("$item")
            done < <(find "$path" -mindepth 1 2>/dev/null)

            # If find failed due to permissions, use trash_count as estimate
            if [[ ${#trash_items[@]} -eq 0 ]] && [[ "$trash_count" -gt 0 ]]; then
                log_debug "Using AppleScript count: $trash_count items (direct access denied)"
                # Create placeholder array to match count
                for ((i=1; i<=trash_count; i++)); do
                    trash_items+=("item_$i")
                done
            fi

            # Calculate total size (only if we have direct access to files)
            local total_size=0
            local has_size_info=false
            for item in "${trash_items[@]}"; do
                if [[ -e "$item" ]]; then
                    has_size_info=true
                    if command -v du >/dev/null 2>&1; then
                        local item_size=$(du -sk "$item" 2>/dev/null | awk '{print $1}')
                        if [[ -n "$item_size" ]] && [[ "$item_size" =~ ^[0-9]+$ ]]; then
                            total_size=$((total_size + item_size * 1024))
                        fi
                    fi
                fi
            done

            # Format size
            local size_formatted=""
            if [[ "$has_size_info" == "true" ]] && [[ $total_size -gt 0 ]]; then
                local size_mb=$((total_size / 1024 / 1024))
                if [[ $size_mb -ge 1024 ]]; then
                    local size_gb=$(awk "BEGIN {printf \"%.2f\", $total_size / 1073741824}")
                    size_formatted="${size_gb} GB"
                else
                    local size_mb_float=$(awk "BEGIN {printf \"%.2f\", $total_size / 1048576}")
                    size_formatted="${size_mb_float} MB"
                fi
            else
                size_formatted="unknown size"
            fi

            # Show information about trash
            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to empty trash: $trash_count items"
                if [[ "$has_size_info" == "true" ]]; then
                    print_info "Total size: $size_formatted"
                fi

                if ! is_dry_run && ! confirm "Empty trash? (y/N)" "N"; then
                    log_info "User cancelled trash cleanup"
                    return 1
                fi
            else
                log_info "Emptying trash: $trash_count items ($size_formatted)"
            fi

            # In dry-run mode, just report what would be done
            if is_dry_run; then
                log_info "[DRY-RUN] Would empty trash: $trash_count items ($size_formatted)"
                print_info "[DRY-RUN] Would empty $trash_count items from trash"
                return 0
            fi

            # Use macOS native command to empty trash (most reliable method)
            if [[ -z "$target_user" ]] || [[ "$target_user" == "$USER" ]]; then
                # Current user: use AppleScript
                if command -v osascript >/dev/null 2>&1; then
                    log_info "Emptying trash using macOS Finder..."
                    if osascript -e 'tell application "Finder" to empty trash' 2>/dev/null; then
                        log_success "Trash emptied successfully"
                        return 0
                    else
                        log_warn "Failed to empty trash using Finder, trying manual deletion..."
                    fi
                fi
            else
                # Other user: use manual deletion (AppleScript won't work for other users)
                log_info "Emptying trash for user $target_user using manual deletion..."
            fi

            # Fallback: manual deletion if osascript fails
            local deleted=0
            local failed=0

            # For multi-user mode, delete entire trash directory content
            if [[ -n "$target_user" ]] && [[ "$target_user" != "$USER" ]] && [[ -d "$path" ]]; then
                if sudo rm -rf "$path"/* 2>/dev/null; then
                    deleted=$trash_count
                    log_success "Deleted $deleted items from trash (user: $target_user)"
                else
                    log_warn "Failed to delete trash items for user: $target_user"
                    return 1
                fi
            else
                # Current user: delete items individually
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
            fi

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

            if [[ "$SKIP_CATEGORY_CONFIRM" != "true" ]]; then
                print_warning "About to empty trash: ${#trash_items[@]} items"
                if ! confirm "Empty trash? (y/N)" "N"; then
                    return 1
                fi
            else
                log_info "Emptying trash: ${#trash_items[@]} items"
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
