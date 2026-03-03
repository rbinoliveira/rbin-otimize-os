#!/usr/bin/env bash

# OS Optimization Scripts - Main Entry Point
# Version: 2.0.0
# Description: Visual interactive menu for system optimization

set -euo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============ Terminal & Colors ============

_setup_colors() {
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        C_RESET=$(tput sgr0)
        C_BOLD=$(tput bold)
        C_DIM=$(tput dim 2>/dev/null || echo '')
        C_GREEN=$(tput setaf 2)
        C_YELLOW=$(tput setaf 3)
        C_RED=$(tput setaf 1)
        C_BLUE=$(tput setaf 4)
        C_CYAN=$(tput setaf 6)
        C_WHITE=$(tput setaf 7)
        TERM_COLS=$(tput cols 2>/dev/null || echo 60)
    else
        C_RESET='\033[0m'
        C_BOLD='\033[1m'
        C_DIM='\033[2m'
        C_GREEN='\033[0;32m'
        C_YELLOW='\033[1;33m'
        C_RED='\033[0;31m'
        C_BLUE='\033[0;34m'
        C_CYAN='\033[0;36m'
        C_WHITE='\033[0;37m'
        TERM_COLS=60
    fi
    # Clamp width for the UI box
    [[ $TERM_COLS -gt 64 ]] && BOX_WIDTH=64 || BOX_WIDTH=$TERM_COLS
}

_setup_colors

# ============ OS Detection ============

OS_TYPE=""
OS_DIR=""
DRY_RUN=false

detect_os() {
    OS_TYPE=$(uname -s)
    case "$OS_TYPE" in
        Darwin) OS_DIR="mac" ;;
        Linux)  OS_DIR="linux" ;;
        *)
            echo -e "${C_RED}Unsupported OS: $OS_TYPE${C_RESET}" >&2
            exit 1
            ;;
    esac
    if [[ ! -d "${SCRIPT_DIR}/${OS_DIR}" ]]; then
        echo -e "${C_RED}Platform directory not found: ${SCRIPT_DIR}/${OS_DIR}${C_RESET}" >&2
        exit 2
    fi
}

# ============ Setup Check ============

check_setup() {
    local needs_setup=false
    if [[ ! -d "${SCRIPT_DIR}/mac" ]] || [[ ! -d "${SCRIPT_DIR}/linux" ]] || \
       [[ ! -d "${SCRIPT_DIR}/lib" ]] || [[ ! -d "${SCRIPT_DIR}/config" ]]; then
        needs_setup=true
    fi
    if [[ -f "${SCRIPT_DIR}/mac/clean-memory.sh" ]] && \
       [[ ! -x "${SCRIPT_DIR}/mac/clean-memory.sh" ]]; then
        needs_setup=true
    fi
    if [[ "$needs_setup" == "true" ]]; then
        local install_script="${SCRIPT_DIR}/scripts/install.sh"
        if [[ -f "$install_script" ]] && [[ -x "$install_script" ]]; then
            bash "$install_script" || { echo "Installation failed." >&2; exit 2; }
        else
            echo "Install script not found: $install_script" >&2
            exit 2
        fi
    fi
}

# ============ Live System Stats ============

get_free_ram_human() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        local page_size free_pages
        page_size=$(pagesize 2>/dev/null || echo 4096)
        free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
        if [[ -n "$free_pages" ]] && [[ "$free_pages" =~ ^[0-9]+$ ]]; then
            awk -v pages="$free_pages" -v psize="$page_size" \
                'BEGIN { mb=pages*psize/1048576; if(mb>=1024) printf "%.1f GB\n",mb/1024; else printf "%d MB\n",mb }'
        else
            echo "—"
        fi
    else
        awk '/MemAvailable/ { mb=$2/1024; if(mb>=1024) printf "%.1f GB\n",mb/1024; else printf "%d MB\n",mb }' \
            /proc/meminfo 2>/dev/null || echo "—"
    fi
}

get_free_disk_human() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        df -H / 2>/dev/null | awk 'NR==2 {print $4}' || echo "—"
    else
        df -H / 2>/dev/null | awk 'NR==2 {print $4}' || echo "—"
    fi
}

get_cpu_usage() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        local idle
        idle=$(top -l 1 -s 0 2>/dev/null | awk '/CPU usage/ {gsub(/%/,"",$7); print $7}' || echo "")
        if [[ -n "$idle" ]] && [[ "$idle" =~ ^[0-9.]+$ ]]; then
            awk -v idle="$idle" 'BEGIN { printf "%.0f%%\n", 100-idle }'
        else
            echo "—"
        fi
    else
        top -bn1 2>/dev/null | awk '/Cpu/ {printf "%.0f%%", 100 - $8}' || echo "—"
    fi
}

get_os_label() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        local ver
        ver=$(sw_vers -productVersion 2>/dev/null || echo "")
        echo "macOS ${ver}"
    else
        grep "^PRETTY_NAME=" /etc/os-release 2>/dev/null \
            | cut -d= -f2 | tr -d '"' || echo "Linux"
    fi
}

# ============ Box Drawing Helpers ============

# Pad a string to exactly N visible chars, then wrap in box sides
_box_line() {
    # Usage: _box_line "  content text" inner_width
    local content="$1"
    local inner=$2
    # Strip ANSI for length calculation
    local visible
    visible=$(printf '%s' "$content" | sed 's/\x1b\[[0-9;]*m//g')
    local vlen=${#visible}
    local pad=$(( inner - vlen ))
    [[ $pad -lt 0 ]] && pad=0
    printf '║%s%*s║\n' "$content" "$pad" ''
}

_box_top() {
    local inner=$1
    printf '╔'
    printf '═%.0s' $(seq 1 "$inner")
    printf '╗\n'
}

_box_sep() {
    local inner=$1
    printf '╠'
    printf '═%.0s' $(seq 1 "$inner")
    printf '╣\n'
}

_box_bot() {
    local inner=$1
    printf '╚'
    printf '═%.0s' $(seq 1 "$inner")
    printf '╝\n'
}

# ============ Menu Rendering ============

draw_menu() {
    local free_ram free_disk cpu_pct os_label dry_label
    free_ram=$(get_free_ram_human)
    free_disk=$(get_free_disk_human)
    cpu_pct=$(get_cpu_usage)
    os_label=$(get_os_label)
    dry_label=""
    [[ "$DRY_RUN" == "true" ]] && dry_label="  ${C_YELLOW}[dry-run]${C_RESET}"

    local inner=$(( BOX_WIDTH - 2 ))

    clear 2>/dev/null || printf '\033[2J\033[H'

    # Top border
    _box_top "$inner"

    # Title
    local title="${C_BOLD}${C_CYAN}  rbin-otimize-os${C_RESET}${dry_label}"
    _box_line "$title" "$inner"

    # OS line
    local os_line="${C_DIM}  ${os_label}${C_RESET}"
    _box_line "$os_line" "$inner"

    # Separator
    _box_sep "$inner"

    # Stats bar
    local stats="  ${C_GREEN}RAM livre: ${free_ram}${C_RESET}   ${C_BLUE}Disco livre: ${free_disk}${C_RESET}   ${C_YELLOW}CPU: ${cpu_pct}${C_RESET}"
    _box_line "$stats" "$inner"

    # Separator
    _box_sep "$inner"

    # Empty line
    _box_line "" "$inner"

    # Option 1
    local opt1="${C_BOLD}${C_WHITE}  [1]  Melhorar Performance${C_RESET}"
    _box_line "$opt1" "$inner"
    local opt1d="${C_DIM}       Limpa memória RAM e otimiza CPU${C_RESET}"
    _box_line "$opt1d" "$inner"

    _box_line "" "$inner"

    # Option 2
    local opt2="${C_BOLD}${C_WHITE}  [2]  Maiores Consumidores de Espaco${C_RESET}"
    _box_line "$opt2" "$inner"
    local opt2d="${C_DIM}       Mostra pastas e arquivos que mais ocupam disco${C_RESET}"
    _box_line "$opt2d" "$inner"

    _box_line "" "$inner"

    # Option 3
    local opt3="${C_BOLD}${C_WHITE}  [3]  Analisar e Limpar Disco${C_RESET}"
    _box_line "$opt3" "$inner"
    local opt3d="${C_DIM}       Analisa caches por categoria e oferece limpeza${C_RESET}"
    _box_line "$opt3d" "$inner"

    _box_line "" "$inner"

    # Exit
    local opt0="${C_DIM}  [0]  Sair${C_RESET}"
    _box_line "$opt0" "$inner"

    _box_line "" "$inner"

    # Bottom border
    _box_bot "$inner"

    printf '\n'
    printf "${C_BOLD}Escolha: ${C_RESET}"
}

# ============ Script Execution ============

_run_script() {
    local script_path="$1"
    shift
    local extra_args=("$@")

    if [[ ! -f "$script_path" ]]; then
        echo -e "\n${C_RED}Script nao encontrado: $script_path${C_RESET}\n"
        return 1
    fi
    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path" 2>/dev/null || {
            echo -e "\n${C_RED}Sem permissao para executar: $script_path${C_RESET}\n"
            return 1
        }
    fi

    echo ""
    printf "${C_DIM}%.0s─${C_RESET}" $(seq 1 "${BOX_WIDTH}")
    echo ""

    set +e
    if [[ "$DRY_RUN" == "true" ]]; then
        bash "$script_path" --dry-run "${extra_args[@]+"${extra_args[@]}"}"
    else
        bash "$script_path" "${extra_args[@]+"${extra_args[@]}"}"
    fi
    local exit_code=$?
    set -e

    echo ""
    printf "${C_DIM}%.0s─${C_RESET}" $(seq 1 "${BOX_WIDTH}")
    echo ""

    if [[ $exit_code -eq 0 ]]; then
        echo -e "${C_GREEN}Concluido com sucesso.${C_RESET}"
    else
        echo -e "${C_YELLOW}Finalizado com codigo: ${exit_code}${C_RESET}"
    fi

    echo ""
    printf "${C_DIM}Pressione Enter para voltar ao menu...${C_RESET}"
    read -r
}

run_performance() {
    _run_script "${SCRIPT_DIR}/${OS_DIR}/optimize-all.sh"
}

run_analyze() {
    _run_script "${SCRIPT_DIR}/${OS_DIR}/analyze-disk.sh"
}

run_cleanup() {
    _run_script "${SCRIPT_DIR}/${OS_DIR}/cleanup-disk.sh"
}

# ============ Argument Parsing ============

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)  DRY_RUN=true; shift ;;
            -h|--help)     _show_help; exit 0 ;;
            --version)     echo "rbin-otimize-os v${SCRIPT_VERSION}"; exit 0 ;;
            *)
                echo -e "${C_RED}Opcao desconhecida: $1${C_RESET}" >&2
                _show_help
                exit 1
                ;;
        esac
    done
}

_show_help() {
    cat <<EOF
rbin-otimize-os v${SCRIPT_VERSION}

Uso: $0 [OPCOES]

Opcoes:
  -n, --dry-run    Simula operacoes sem executar
  -h, --help       Exibe esta ajuda
  --version        Exibe versao

Menu interativo com 3 operacoes:
  1) Melhorar Performance          — limpa memoria e otimiza CPU
  2) Maiores Consumidores de Espaco — pastas e arquivos viloes
  3) Analisar e Limpar Disco        — analise por categoria + wizard de limpeza
EOF
}

# ============ Main Loop ============

main() {
    parse_arguments "$@"
    check_setup
    detect_os

    trap 'echo ""; echo "Saindo..."; exit 0' INT TERM

    while true; do
        draw_menu
        local choice
        read -r choice

        case "$choice" in
            1) run_performance ;;
            2) run_analyze ;;
            3) run_cleanup ;;
            0|q|Q) echo -e "\n${C_DIM}Ate logo.${C_RESET}\n"; exit 0 ;;
            '')    : ;;  # redraw on empty enter
            *)
                echo -e "\n${C_YELLOW}Opcao invalida: ${choice}${C_RESET}"
                sleep 0.8
                ;;
        esac
    done
}

main "$@"
