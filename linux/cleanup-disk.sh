#!/usr/bin/env bash

# Linux Disk Cleanup Script
# Version: 1.0.0
# Description: Clean up disk space by removing unnecessary files

set -euo pipefail

# Script configuration
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${HOME}/.os-optimize/logs"
LOG_FILE=""

# Execution flags
DRY_RUN=false
VERBOSE=false
QUIET=false
FORCE=false
MIN_AGE_DAYS=0

# Source common libraries
if [[ -f "${PROJECT_ROOT}/lib/common.sh" ]]; then
    source "${PROJECT_ROOT}/lib/common.sh"
else
    echo "Error: lib/common.sh not found" >&2
    exit 1
fi

if [[ -f "${PROJECT_ROOT}/lib/disk_analysis.sh" ]]; then
    source "${PROJECT_ROOT}/lib/disk_analysis.sh"
else
    echo "Error: lib/disk_analysis.sh not found" >&2
    exit 1
fi

if [[ -f "${PROJECT_ROOT}/lib/cleanup_preview.sh" ]]; then
    source "${PROJECT_ROOT}/lib/cleanup_preview.sh"
else
    echo "Error: lib/cleanup_preview.sh not found" >&2
    exit 1
fi

# Initialize logging
init_logging() {
    # Try system log directory first, fallback to user directory
    if [[ -w "/var/log" ]] && sudo -n true 2>/dev/null; then
        if sudo mkdir -p /var/log/os-optimize 2>/dev/null; then
            LOG_DIR="/var/log/os-optimize"
        fi
    fi

    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        chmod 755 "$LOG_DIR" 2>/dev/null || true
        local timestamp=$(date +%Y%m%d-%H%M%S)
        LOG_FILE="${LOG_DIR}/cleanup-disk-${timestamp}.log"

        {
            echo "=========================================="
            echo "Linux Disk Cleanup Script - Log"
            echo "=========================================="
            echo "Timestamp: $(date)"
            echo "Kernel: $(uname -r 2>/dev/null || echo 'unknown')"
            echo "Distribution: $(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME" | cut -d'"' -f2 || echo 'unknown')"
            echo "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
            echo "User: $(whoami 2>/dev/null || echo 'unknown')"
            echo "Script Version: $SCRIPT_VERSION"
            echo "Flags: DRY_RUN=$DRY_RUN, VERBOSE=$VERBOSE, QUIET=$QUIET, FORCE=$FORCE, MIN_AGE=$MIN_AGE_DAYS"
            echo "=========================================="
            echo ""
        } >> "$LOG_FILE" 2>/dev/null || true

        log_info "Logging initialized: $LOG_FILE"
        return 0
    else
        print_warning "Cannot create log directory: $LOG_DIR (logging disabled)"
        return 1
    fi
}

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --quiet|-q)
                QUIET=true
                shift
                ;;
            --force|-f)
                FORCE=true
                FORCE_MODE=true
                shift
                ;;
            --all-users)
                ALL_USERS=true
                shift
                ;;
            --min-age)
                MIN_AGE_DAYS="$2"
                shift 2
                ;;
            --min-age=*)
                MIN_AGE_DAYS="${1#*=}"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate MIN_AGE_DAYS
    if ! [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
        print_error "Invalid min-age: $MIN_AGE_DAYS (must be a non-negative integer)"
        exit 1
    fi

    # Validate ALL_USERS requires sudo
    if [[ "$ALL_USERS" == "true" ]]; then
        if ! require_sudo; then
            print_error "--all-users requires sudo access"
            exit 2
        fi
    fi
}

# Show help message
show_help() {
    cat << EOF
Linux Disk Cleanup Script v$SCRIPT_VERSION

Usage: $0 [OPTIONS]

Options:
    --dry-run, -n          Show what would be cleaned without executing
    --verbose, -v          Show detailed output
    --quiet, -q            Suppress non-error output
    --force, -f            Skip confirmation prompts
    --all-users            Clean files for ALL users on the system (requires sudo)
    --min-age=N            Only clean files older than N days (default: 0)
    -h, --help             Show this help message

Description:
    Cleans up disk space by removing unnecessary files from:
    - Caches (user and system)
    - Logs
    - Temporary files
    - Browser trash
    - Downloads (if --min-age specified)
    - Package manager caches (apt, yum, dnf, pacman)
    - Android Studio caches
    - Gradle caches
    - React Native caches (Metro, Watchman, Haste)
    - Node modules cache
    - Docker containers/images/volumes
    - Snap package cache
    - Old kernels (requires sudo)

User Scope:
    By default, only the current user's files are cleaned.
    Use --all-users to clean files for ALL users on the system.

    ⚠ WARNING: --all-users requires sudo and will clean files for:
       - All user home directories (/home/* and /root)
       - All user caches and logs
       - All user application data

Warning: Some operations are irreversible. Use --dry-run first.

EOF
}

# Clean a specific category
clean_category() {
    local category="$1"

    log_info "Cleaning category: $category"

    if delete_category_files "$category" "$MIN_AGE_DAYS"; then
        print_success "Cleaned category: $category"
        return 0
    else
        print_warning "Failed to clean category: $category"
        return 1
    fi
}

# Display category menu and get user selection
select_categories_to_clean() {
    local categories=("$@")
    local -a selected_indices=()

    # Display header (redirect to stderr so it's visible even in subshell)
    print_info "===============================================" >&2
    print_info "Select categories to clean:" >&2
    print_info "===============================================" >&2
    print_info "" >&2

    # Display numbered list
    local idx=1
    for category in "${categories[@]}"; do
        # Get category path for display
        local category_path=""
        if command -v get_category_path >/dev/null 2>&1; then
            category_path=$(get_category_path "$category")
        fi

        # Special handling for categories without single path
        if [[ -z "$category_path" ]]; then
            case "$category" in
                node_modules)
                    category_path="Multiple project directories"
                    ;;
                volumes)
                    category_path="Docker volumes (unused only)"
                    ;;
                build_artifacts)
                    category_path="Multiple project directories"
                    ;;
                *)
                    category_path="Various locations"
                    ;;
            esac
        fi

        # Format category name for display
        local category_display="$category"
        case "$category" in
            browser_trash)
                category_display="Browser Trash"
                ;;
            node_modules)
                category_display="node_modules"
                ;;
            build_artifacts)
                category_display="Build Artifacts"
                ;;
            *)
                category_display=$(echo "$category" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1')
                ;;
        esac

        printf "  %2d) %-35s (%s)\n" "$idx" "$category_display" "$category_path" >&2
        idx=$((idx + 1))
    done

    print_info "" >&2
    print_info "Enter numbers separated by comma (e.g., 1,2,3)" >&2
    print_info "Or type 'all' to select everything" >&2
    print_info "" >&2

    # Read user input
    local input
    read -r -p "Your choice: " input </dev/tty

    # Handle empty input
    if [[ -z "$input" ]]; then
        return 1
    fi

    # Handle 'all' selection
    if [[ "$input" == "all" ]] || [[ "$input" == "ALL" ]]; then
        for ((i=1; i<=${#categories[@]}; i++)); do
            selected_indices+=($i)
        done
    else
        # Parse comma-separated values only
        IFS=',' read -ra selections <<< "$input"
        for selection in "${selections[@]}"; do
            # Trim whitespace
            selection=$(echo "$selection" | xargs)

            # Check if it's a valid number
            if [[ "$selection" =~ ^[0-9]+$ ]]; then
                if [[ $selection -ge 1 ]] && [[ $selection -le ${#categories[@]} ]]; then
                    selected_indices+=($selection)
                else
                    print_warning "Invalid selection: $selection (out of range)" >&2
                fi
            else
                print_warning "Invalid selection: $selection (not a number)" >&2
            fi
        done
    fi

    # Remove duplicates and sort
    if [[ ${#selected_indices[@]} -eq 0 ]]; then
        print_warning "No categories selected" >&2
        return 1
    fi

    selected_indices=($(printf '%s\n' "${selected_indices[@]}" | sort -nu))

    # Display selected categories for confirmation
    print_info "" >&2
    print_info "Selected categories:" >&2
    for idx in "${selected_indices[@]}"; do
        local category="${categories[$((idx-1))]}"
        local category_display="$category"
        case "$category" in
            browser_trash)
                category_display="Browser Trash"
                ;;
            node_modules)
                category_display="node_modules"
                ;;
            build_artifacts)
                category_display="Build Artifacts"
                ;;
            *)
                category_display=$(echo "$category" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1')
                ;;
        esac
        print_info "  - $category_display" >&2
    done
    print_info "" >&2

    # Export selected indices for main function
    echo "${selected_indices[@]}"
    return 0
}

# Main execution
main() {
    # Parse arguments
    parse_arguments "$@"

    # Initialize logging
    init_logging

    # Validate OS
    if ! validate_os; then
        exit 1
    fi

    print_info "Linux Disk Cleanup Script v$SCRIPT_VERSION"
    print_info "=============================================="
    print_info ""

    if is_dry_run; then
        print_warning "DRY-RUN MODE: No files will be deleted"
        print_info ""
    fi

    if [[ "$FORCE" == "true" ]]; then
        print_warning "FORCE MODE: Confirmations disabled"
        print_info ""
    fi

    # Note: Use analyze-disk.sh to preview what will be cleaned
    if ! is_dry_run && [[ "$FORCE" != "true" ]]; then
        print_info "Note: Use 'analyze-disk.sh' to preview disk usage before cleaning"
        print_info ""
    fi

    # Get all categories
    local categories=$(get_cleanup_categories)
    local -a category_array=($categories)
    local cleaned=0
    local failed=0

    # Interactive category selection (unless force or dry-run)
    local -a selected_indices=()
    if ! is_dry_run && [[ "$FORCE" != "true" ]]; then
        local selection_output
        if selection_output=$(select_categories_to_clean "${category_array[@]}"); then
            selected_indices=($selection_output)
        else
            print_warning "Cleanup cancelled"
            exit 0
        fi

        # Final confirmation
        if ! confirm "Confirm cleanup of selected categories? (y/N)" "N"; then
            print_warning "Cleanup cancelled"
            exit 0
        fi

        # Skip individual category confirmations since user already confirmed
        export SKIP_CATEGORY_CONFIRM=true
    else
        # In force or dry-run mode, clean all categories
        for ((i=1; i<=${#category_array[@]}; i++)); do
            selected_indices+=($i)
        done
    fi

    print_info ""
    print_info "Starting cleanup..."
    print_info ""

    # Determine which users to clean
    local -a user_homes=()
    if [[ "$ALL_USERS" == "true" ]]; then
        print_info "Cleaning for ALL users on the system..."
        print_info ""
        while IFS= read -r user_home; do
            user_homes+=("$user_home")
        done < <(get_all_user_homes)

        if [[ ${#user_homes[@]} -eq 0 ]]; then
            print_error "No user home directories found"
            exit 1
        fi

        print_info "Found ${#user_homes[@]} user(s) to clean"
        print_info ""
    else
        user_homes=("$HOME")
    fi

    # Clean selected categories for each user
    for user_home in "${user_homes[@]}"; do
        local username=$(basename "$user_home")

        if [[ "$ALL_USERS" == "true" ]]; then
            print_info "=========================================="
            print_info "Cleaning for user: $username"
            print_info "=========================================="
            print_info ""
        fi

        # Export HOME_OVERRIDE so cleanup functions can use it
        export HOME_OVERRIDE="$user_home"

        for idx in "${selected_indices[@]}"; do
            local category="${category_array[$((idx-1))]}"
            if clean_category "$category"; then
                cleaned=$((cleaned + 1))
            else
                failed=$((failed + 1))
            fi
        done

        if [[ "$ALL_USERS" == "true" ]]; then
            print_info ""
        fi
    done

    # Unset HOME_OVERRIDE
    unset HOME_OVERRIDE

    # Summary
    print_info ""
    print_info "=============================================="
    print_success "Cleanup completed!"
    print_info "Categories cleaned: $cleaned"
    if [[ $failed -gt 0 ]]; then
        print_warning "Categories failed: $failed"
    fi
    print_info ""

    if [[ -n "$LOG_FILE" ]]; then
        print_info "Log file: $LOG_FILE"
    fi
}

# Run main function
main "$@"
