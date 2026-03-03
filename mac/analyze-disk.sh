#!/usr/bin/env bash

# macOS — Maiores Consumidores de Espaço (Vilões)
# Version: 2.0.0
# Bash 3 compatible

set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in --dry-run|-n) DRY_RUN=true ;; esac
done

# ============ Colors ============

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    R=$(tput sgr0); B=$(tput bold)
    DIM=$(tput dim 2>/dev/null || printf '')
    GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
    BLUE=$(tput setaf 4); CYAN=$(tput setaf 6); WHITE=$(tput setaf 7)
    TERM_COLS=$(tput cols 2>/dev/null || echo 72)
else
    R='\033[0m'; B='\033[1m'; DIM='\033[2m'
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[0;37m'
    TERM_COLS=72
fi

[[ $TERM_COLS -gt 80 ]] && WIDTH=80 || WIDTH=$TERM_COLS
BAR_MAX=24
INNER=$(( WIDTH - 2 ))

# ============ Box Helpers ============

_line() {
    local content="$1" inner=$2
    local visible
    visible=$(printf '%s' "$content" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( inner - ${#visible} ))
    [[ $pad -lt 0 ]] && pad=0
    printf '║%s%*s║\n' "$content" "$pad" ''
}
_top()   { printf '╔'; printf '═%.0s' $(seq 1 "$1"); printf '╗\n'; }
_sep()   { printf '╠'; printf '═%.0s' $(seq 1 "$1"); printf '╣\n'; }
_bot()   { printf '╚'; printf '═%.0s' $(seq 1 "$1"); printf '╝\n'; }
_blank() { _line "" "$INNER"; }

# ============ Helpers ============

_human() {
    local b=$1
    if   [[ $b -ge 1073741824 ]]; then awk -v b="$b" 'BEGIN{printf "%.1f GB",b/1073741824}'
    elif [[ $b -ge 1048576    ]]; then awk -v b="$b" 'BEGIN{printf "%.0f MB",b/1048576}'
    elif [[ $b -ge 1024       ]]; then awk -v b="$b" 'BEGIN{printf "%.0f KB",b/1024}'
    else echo "${b} B"
    fi
}

_bar() {
    local bytes=$1 max_bytes=$2
    local filled=0
    [[ $max_bytes -gt 0 ]] && filled=$(( bytes * BAR_MAX / max_bytes ))
    [[ $filled -gt $BAR_MAX ]] && filled=$BAR_MAX
    local empty=$(( BAR_MAX - filled ))

    local color=$GREEN
    [[ $filled -ge $(( BAR_MAX * 35 / 100 )) ]] && color=$YELLOW
    [[ $filled -ge $(( BAR_MAX * 70 / 100 )) ]] && color=$RED

    local bar="${color}"
    local i
    for (( i=0; i<filled; i++ )); do bar+='█'; done
    bar+="${DIM}"
    for (( i=0; i<empty; i++ )); do bar+='░'; done
    bar+="${R}"
    printf '%s' "$bar"
}

_disk_overview() {
    local total_kb used_kb avail_kb
    total_kb=$(df -k / 2>/dev/null | awk 'NR==2{print $2}')
    used_kb=$(df -k  / 2>/dev/null | awk 'NR==2{print $3}')
    avail_kb=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')

    local total_b=$(( total_kb * 1024 ))
    local used_b=$(( used_kb * 1024 ))
    local avail_b=$(( avail_kb * 1024 ))

    local total_h used_h avail_h
    total_h=$(_human "$total_b")
    used_h=$(_human "$used_b")
    avail_h=$(_human "$avail_b")

    local pct=0
    [[ $total_kb -gt 0 ]] && pct=$(( used_kb * 100 / total_kb ))
    local filled=$(( pct * BAR_MAX / 100 ))
    [[ $filled -gt $BAR_MAX ]] && filled=$BAR_MAX
    local empty=$(( BAR_MAX - filled ))

    local bar_color=$GREEN
    [[ $pct -ge 70 ]] && bar_color=$YELLOW
    [[ $pct -ge 90 ]] && bar_color=$RED

    local bar="${bar_color}"
    local i
    for (( i=0; i<filled; i++ )); do bar+='█'; done
    bar+="${DIM}"
    for (( i=0; i<empty;  i++ )); do bar+='░'; done
    bar+="${R}"

    _line "  ${B}${WHITE}Disco${R}  ${bar}  ${used_h} / ${total_h}  ${DIM}(${avail_h} livre)${R}" "$INNER"
}

# ============ Spinner ============

_SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
_SPIN_IDX=0

_spin_tick() {
    local ch="${_SPIN_CHARS:$_SPIN_IDX:1}"
    printf '\r  %s  %s' "$ch" "$1"
    _SPIN_IDX=$(( (_SPIN_IDX + 1) % 10 ))
}
_spin_clear() { printf '\r\033[2K'; }

# ============ Scan ============

SCAN_DIR="$(mktemp -d)"
trap 'rm -rf "$SCAN_DIR"' EXIT

# Scan top-level dirs in a given root, write results to SCAN_DIR/<label>_<idx>
_scan_root() {
    local root="$1" prefix="$2"
    local idx=0
    while IFS= read -r -d '' entry; do
        local name; name=$(basename "$entry")
        # Skip hidden dot-dirs except a few known large ones
        if [[ "$name" == .* ]]; then
            case "$name" in
                .npm|.yarn|.pnpm*|.nvm|.gradle|.android|.expo|.turbo|\
                .bun|.cache|.gem|.bundle|.pub-cache|.Trash) ;;
                *) continue ;;
            esac
        fi
        (
            bytes=$( { du -sk "$entry" 2>/dev/null || true; } \
                | awk 'NR==1{print $1*1024; exit} END{if(NR==0) print 0}' )
            printf '%s|%s|%s\n' "$bytes" "$name" "$entry" \
                > "${SCAN_DIR}/${prefix}_$(printf '%04d' $idx)"
        ) &
        idx=$(( idx + 1 ))
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

_scan_all() {
    # Home top-level
    _scan_root "$HOME" "home"
    # Library sub-dirs (many large caches live here)
    _scan_root "$HOME/Library" "lib"

    local total_jobs
    total_jobs=$(jobs -p | wc -l | tr -d ' ')
    local done_count=0

    while true; do
        done_count=$(ls "$SCAN_DIR" 2>/dev/null | wc -l | tr -d ' ')
        _spin_tick "Escaneando... (${done_count} itens)"
        local running
        running=$(jobs -rp 2>/dev/null | wc -l | tr -d ' ')
        [[ $running -eq 0 ]] && break
        sleep 0.1
    done
    _spin_clear
    wait
}

# ============ Display ============

_display() {
    # Collect all results, sort by bytes desc
    local results_file="${SCAN_DIR}/_sorted"

    # Merge all result files, sort numerically descending
    cat "${SCAN_DIR}"/home_* "${SCAN_DIR}"/lib_* 2>/dev/null \
        | sort -t'|' -k1 -rn \
        > "$results_file"

    # Find max for bar scaling (top entry)
    local max_bytes=1
    max_bytes=$(head -1 "$results_file" 2>/dev/null | cut -d'|' -f1)
    [[ -z "$max_bytes" || $max_bytes -eq 0 ]] && max_bytes=1

    clear 2>/dev/null || printf '\033[2J\033[H'

    _top "$INNER"
    _line "  ${B}${CYAN}Maiores Consumidores de Espaço${R}  ${DIM}macOS $(sw_vers -productVersion 2>/dev/null)${R}" "$INNER"
    _sep "$INNER"
    _disk_overview
    _sep "$INNER"
    _blank

    local lbl_pad=26 size_pad=8
    local count=0
    local rank=1

    while IFS='|' read -r bytes name path; do
        [[ -z "$bytes" || $bytes -eq 0 ]] && continue
        [[ $count -ge 20 ]] && break

        local h; h=$(_human "$bytes")
        local bar; bar=$(_bar "$bytes" "$max_bytes")

        # Rank color
        local rank_color=$WHITE
        [[ $rank -le 3 ]] && rank_color=$RED
        [[ $rank -ge 4 && $rank -le 8 ]] && rank_color=$YELLOW

        # Truncate name
        local lbl="$name"
        [[ ${#lbl} -gt $lbl_pad ]] && lbl="${lbl:0:$((lbl_pad-1))}…"

        local row
        row="  ${rank_color}$(printf '%2d' $rank)${R}  ${WHITE}$(printf '%-*s' "$lbl_pad" "$lbl")${R}  ${bar}  $(printf '%*s' "$size_pad" "$h")"
        _line "$row" "$INNER"

        rank=$(( rank + 1 ))
        count=$(( count + 1 ))
    done < "$results_file"

    _blank
    _bot "$INNER"
}

# ============ Main ============

main() {
    printf '\033[2J\033[H'
    _top "$INNER"
    _line "  ${B}${CYAN}Maiores Consumidores de Espaço${R}" "$INNER"
    _sep "$INNER"
    _blank
    _line "  ${DIM}Escaneando diretórios, aguarde...${R}" "$INNER"
    _blank
    _bot "$INNER"
    printf '\n'

    _scan_all
    _display

    printf '\n'
}

main "$@"
