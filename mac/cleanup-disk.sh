#!/usr/bin/env bash

# macOS Disk Cleanup Script
# Version: 2.0.0
# Description: Wizard interativo de limpeza de disco seguindo CLEANUP_WIZARD_STEPS.md

set -euo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${HOME}/.os-optimize/logs"
LOG_FILE=""

DRY_RUN=false
VERBOSE=false
QUIET=false
FORCE=false
MIN_AGE_DAYS=0
HOME_OVERRIDE="${HOME_OVERRIDE:-}"   # used by lib/cleanup_preview.sh (set -u safe)

# ============ Library Dependencies ============
if [[ -f "${PROJECT_ROOT}/lib/common.sh" ]]; then
    source "${PROJECT_ROOT}/lib/common.sh"
else
    echo "Error: lib/common.sh not found" >&2; exit 1
fi
if [[ -f "${PROJECT_ROOT}/lib/disk_analysis.sh" ]]; then
    source "${PROJECT_ROOT}/lib/disk_analysis.sh"
else
    echo "Error: lib/disk_analysis.sh not found" >&2; exit 1
fi
if [[ -f "${PROJECT_ROOT}/lib/cleanup_preview.sh" ]]; then
    source "${PROJECT_ROOT}/lib/cleanup_preview.sh"
else
    echo "Error: lib/cleanup_preview.sh not found" >&2; exit 1
fi

# ============ Colors ============
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
    C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
    C_RED=$(tput setaf 1); C_CYAN=$(tput setaf 6)
    C_BLUE=$(tput setaf 4)
    C_DIM=$(tput dim 2>/dev/null || echo '')
    C_WHITE=$(tput setaf 7)
else
    C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
    C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_WHITE='\033[0;37m'
    C_BLUE='\033[0;34m'
fi

# ============ Logging ============
init_logging() {
    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        chmod 755 "$LOG_DIR" 2>/dev/null || true
        local timestamp=$(date +%Y%m%d-%H%M%S)
        LOG_FILE="${LOG_DIR}/cleanup-disk-${timestamp}.log"
        {
            echo "=========================================="
            echo "macOS Disk Cleanup Wizard - Log"
            echo "=========================================="
            echo "Timestamp: $(date)"
            echo "macOS Version: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
            echo "User: $(whoami 2>/dev/null || echo 'unknown')"
            echo "Script Version: $SCRIPT_VERSION"
            echo "Flags: DRY_RUN=$DRY_RUN, FORCE=$FORCE, MIN_AGE=$MIN_AGE_DAYS"
            echo "=========================================="
            echo ""
        } >> "$LOG_FILE" 2>/dev/null || true
        log_info "Logging initialized: $LOG_FILE"
    else
        echo "Warning: Cannot create log directory" >&2
    fi
}

# ============ Argument Parsing ============
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) DRY_RUN=true; shift ;;
            --verbose|-v) VERBOSE=true; shift ;;
            --quiet|-q)   QUIET=true; shift ;;
            --force|-f)   FORCE=true; FORCE_MODE=true; shift ;;
            --all-users)  ALL_USERS=true; shift ;;
            --min-age)    MIN_AGE_DAYS="$2"; shift 2 ;;
            --min-age=*)  MIN_AGE_DAYS="${1#*=}"; shift ;;
            --mode)       CLEANUP_MODE="$2"; shift 2 ;;
            --mode=*)     CLEANUP_MODE="${1#*=}"; shift ;;
            -h|--help)    show_help; exit 0 ;;
            *)
                echo -e "${C_RED}Opcao desconhecida: $1${C_RESET}" >&2
                show_help; exit 1
                ;;
        esac
    done
    if ! [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
        echo "Invalid min-age: $MIN_AGE_DAYS" >&2; exit 1
    fi
    if [[ "${ALL_USERS:-false}" == "true" ]] && ! require_sudo; then
        echo "--all-users requires sudo" >&2; exit 2
    fi
}

show_help() {
    cat <<EOF
macOS Disk Cleanup Wizard v$SCRIPT_VERSION

Uso: $0 [OPCOES]

Opcoes:
    --dry-run, -n    Simula sem apagar nada
    --verbose, -v    Saida detalhada
    --quiet, -q      Saida minima
    --force, -f      Pula confirmacoes (exceto passos de alto risco)
    --min-age=N      So limpa arquivos mais velhos que N dias
    -h, --help       Esta ajuda

O wizard guia por 10 passos agrupados por contexto,
mais 3 passos de alto risco (AVD, SDK, Simuladores iOS)
que sempre pedem confirmacao explicita.
EOF
}

# ============ Helpers ============

# Imprime cabecalho de passo
_step_header() {
    local num="$1" title="$2" risk="${3:-}"
    echo ""
    if [[ "$risk" == "high" ]]; then
        echo -e "${C_RED}${C_BOLD}┌─────────────────────────────────────────────┐${C_RESET}"
        echo -e "${C_RED}${C_BOLD}│  ATENCAO  Passo $num — $title${C_RESET}"
        echo -e "${C_RED}${C_BOLD}└─────────────────────────────────────────────┘${C_RESET}"
    else
        echo -e "${C_CYAN}${C_BOLD}── Passo $num — $title${C_RESET}"
    fi
}

# Pergunta sim/nao retorna 0=sim 1=nao
_ask() {
    local prompt="$1"
    local default="${2:-n}"
    if [[ "$FORCE" == "true" ]] && [[ "$default" != "force_no" ]]; then
        return 0
    fi
    local hint="s/N"
    [[ "$default" == "s" ]] && hint="S/n"
    local resp
    read -r -p "$(echo -e "${C_YELLOW}  ${prompt} [${hint}]: ${C_RESET}")" resp </dev/tty
    [[ -z "$resp" ]] && resp="$default"
    [[ "$resp" =~ ^[SsYy]$ ]]
}

# Executa limpeza de uma lista de categorias
_run_categories() {
    local -a cats=("$@")
    local cleaned=0 failed=0 total=${#cats[@]}
    local i=0
    for cat in "${cats[@]}"; do
        i=$((i+1))
        echo -e "  ${C_DIM}[$i/$total]${C_RESET} Limpando ${C_WHITE}${cat}${C_RESET}..."
        set +e
        # High-risk categories have their own interactive prompt — do NOT redirect
        # output so the user can see it. All others go to the log file.
        case "$cat" in
            android_avd|ios_simulator_devices|android_sdk_old)
                delete_category_files "$cat" "$MIN_AGE_DAYS" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
                rc=${PIPESTATUS[0]}
                ;;
            *)
                delete_category_files "$cat" "$MIN_AGE_DAYS" >> "${LOG_FILE:-/dev/null}" 2>&1
                rc=$?
                ;;
        esac
        set -e
        if [[ $rc -eq 0 ]]; then
            echo -e "  ${C_GREEN}✓${C_RESET} ${cat}"
            cleaned=$((cleaned+1))
        else
            echo -e "  ${C_YELLOW}–${C_RESET} ${cat} (nao encontrado ou cancelado)"
            failed=$((failed+1))
        fi
    done
    echo -e "  ${C_DIM}Concluido: $cleaned limpos, $failed ignorados${C_RESET}"
}

# ============ Wizard ============
run_wizard() {
    local -a selected=()

    echo ""
    echo -e "${C_BOLD}${C_CYAN}  Wizard de Limpeza de Disco${C_RESET}"
    echo -e "${C_DIM}  Responda cada passo. 'N' pula o passo sem apagar nada.${C_RESET}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${C_YELLOW}[dry-run] Nenhum arquivo sera apagado.${C_RESET}"
    fi

    # ------------------------------------------------------------------
    # PASSO 1 — Limpeza geral
    # ------------------------------------------------------------------
    _step_header 1 "Limpeza geral (caches, logs, temporarios, lixeira)"
    echo -e "${C_DIM}  Apaga: ~/Library/Caches, ~/Library/Logs, /tmp, ~/.Trash${C_RESET}"
    echo -e "${C_DIM}  Impacto: nenhum — tudo regenerado automaticamente${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(caches logs temp browser_trash)
    fi

    # ------------------------------------------------------------------
    # PASSO 2 — Caches JS/TS
    # ------------------------------------------------------------------
    _step_header 2 "Caches JS/TS (npm, yarn, pnpm, bun, expo, turbo, Metro)"
    echo -e "${C_DIM}  Apaga: ~/.npm  ~/.yarn/cache  ~/.pnpm-store  ~/.bun/install/cache${C_RESET}"
    echo -e "${C_DIM}         ~/.expo  ~/.turbo  Metro bundler / React Native cache${C_RESET}"
    echo -e "${C_DIM}  Impacto: proximo install sera mais lento (re-download)${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(npm_cache yarn_cache pnpm_store bun_cache expo_cache turborepo_cache react_native)
    fi

    # ------------------------------------------------------------------
    # PASSO 3 — Build outputs dos projetos
    # ------------------------------------------------------------------
    _step_header 3 "Build outputs dos projetos (dist, build, .next, coverage…)"
    echo -e "${C_DIM}  Apaga: pastas dist/ build/ target/ .next/ .nuxt/ coverage/ .nyc_output/${C_RESET}"
    echo -e "${C_DIM}         dentro de ~/dev e similares (profundidade 5)${C_RESET}"
    echo -e "${C_DIM}         + app/build Android e ios/build iOS dentro dos projetos${C_RESET}"
    echo -e "${C_DIM}  Impacto: precisa rodar npm run build / gradlew build para recriar${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(build_artifacts android_project_builds ios_project_builds)
    fi

    # ------------------------------------------------------------------
    # PASSO 4 — Ferramentas de teste (Jest, Playwright, Cypress)
    # ------------------------------------------------------------------
    _step_header 4 "Caches de teste (Jest, Playwright, Cypress)"
    echo -e "${C_DIM}  Apaga: /tmp/jest-*  ~/Library/Caches/ms-playwright  ~/.cache/Cypress${C_RESET}"
    echo -e "${C_DIM}  Impacto: proximo 'npx playwright install' / 'npx cypress install'${C_RESET}"
    echo -e "${C_DIM}           vai re-baixar os binarios dos browsers${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(jest_cache playwright_cache cypress_cache)
    fi

    # ------------------------------------------------------------------
    # PASSO 5 — Python, Ruby, .NET
    # ------------------------------------------------------------------
    _step_header 5 "Caches Python, Ruby e .NET (pip, gem, bundler, NuGet)"
    echo -e "${C_DIM}  Apaga: ~/Library/Caches/pip  ~/.gem/cache  ~/.bundle/cache${C_RESET}"
    echo -e "${C_DIM}         ~/.nuget  ~/.dotnet${C_RESET}"
    echo -e "${C_DIM}  Impacto: proximas instalacoes de pacotes serao mais lentas${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(pip_cache gem_cache ruby_bundler_cache nuget_cache dotnet_cache)
    fi

    # ------------------------------------------------------------------
    # PASSO 6 — Caches iOS/Swift (nao quebra desenvolvimento)
    # ------------------------------------------------------------------
    _step_header 6 "Caches iOS/Swift (SwiftPM, Carthage, logs Xcode)"
    echo -e "${C_DIM}  Apaga: ~/Library/Caches/org.swift.swiftpm${C_RESET}"
    echo -e "${C_DIM}         ~/Library/Caches/org.carthage.CarthageKit${C_RESET}"
    echo -e "${C_DIM}         ~/Library/Logs/CoreSimulator  ~/Library/Logs/DiagnosticReports${C_RESET}"
    echo -e "${C_DIM}  Impacto: proximo build Xcode re-baixa pacotes Swift/Carthage${C_RESET}"
    echo -e "${C_DIM}           Logs sao apenas registros — builds e simuladores nao afetados${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(swiftpm_cache carthage_cache xcode_sim_logs)
    fi

    # ------------------------------------------------------------------
    # PASSO 7 — node_modules dos projetos
    # ------------------------------------------------------------------
    _step_header 7 "node_modules dos projetos em ~/dev"
    echo -e "${C_DIM}  Apaga: todas as pastas node_modules/ encontradas em${C_RESET}"
    echo -e "${C_DIM}         ~/dev ~/projects ~/workspace ~/code ~/Documents ~/Desktop${C_RESET}"
    echo -e "${C_DIM}  Impacto: precisa rodar npm/yarn/pnpm install em cada projeto${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(node_modules)
    fi

    # ------------------------------------------------------------------
    # PASSO 8 — Apps desinstalados e cache VS Code
    # ------------------------------------------------------------------
    _step_header 8 "Configs de apps desinstalados e cache VS Code"
    echo -e "${C_DIM}  Apaga: ~/Library/Application Support/<app> de apps nao instalados${C_RESET}"
    echo -e "${C_DIM}         ~/Library/Application Support/Code/Cache (VS Code)${C_RESET}"
    echo -e "${C_DIM}         ~/.nvm/.cache (downloads do nvm — versoes Node mantidas)${C_RESET}"
    echo -e "${C_DIM}  Impacto: baixo — VS Code recria cache sozinho${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(orphaned_apps vscode_cache nvm_cache)
    fi

    # ------------------------------------------------------------------
    # PASSO 9 — Docker
    # ------------------------------------------------------------------
    _step_header 9 "Docker (VMs e volumes nao usados)"
    echo -e "${C_DIM}  Apaga: ~/Library/Containers/com.docker.docker/Data/vms${C_RESET}"
    echo -e "${C_DIM}         volumes Docker orphaned (containers que nao existem mais)${C_RESET}"
    echo -e "${C_DIM}  Impacto: medio — volumes podem ter dados de containers parados${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(docker volumes)
    fi

    # ------------------------------------------------------------------
    # PASSO 10 — Homebrew
    # ------------------------------------------------------------------
    _step_header 10 "Homebrew (versoes antigas de formulas)"
    echo -e "${C_DIM}  Apaga: ~/Library/Caches/Homebrew + executa 'brew cleanup'${C_RESET}"
    echo -e "${C_DIM}  Impacto: versoes antigas removidas. Reinstale se precisar de versao antiga${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(homebrew_cache homebrew_cleanup)
    fi

    # ------------------------------------------------------------------
    # PASSO A — Emuladores Android (AVD) — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header A "Emuladores Android (AVDs)" high
    echo -e "${C_RED}  Apaga: ~/.android/avd — TODOS os emuladores Android${C_RESET}"
    echo -e "${C_RED}  - Os emuladores sao removidos permanentemente${C_RESET}"
    echo -e "${C_RED}  - Apps instalados nos emuladores serao perdidos${C_RESET}"
    echo -e "${C_RED}  - Precisara recriar AVDs no Android Studio > Device Manager${C_RESET}"
    echo -e "${C_DIM}  Use apenas para comecar do zero com os emuladores.${C_RESET}"
    echo ""
    if _ask "Apagar emuladores Android?" "force_no"; then
        selected+=(android_avd)
    fi

    # ------------------------------------------------------------------
    # PASSO B — Simuladores iOS — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header B "Simuladores iOS" high
    echo -e "${C_RED}  Apaga: ~/Library/Developer/CoreSimulator/Devices${C_RESET}"
    echo -e "${C_RED}  - TODOS os simuladores iOS sao removidos permanentemente${C_RESET}"
    echo -e "${C_RED}  - Apps instalados nos simuladores serao perdidos${C_RESET}"
    echo -e "${C_RED}  - Xcode recria simuladores padrao ao abrir${C_RESET}"
    echo -e "${C_RED}  - Simuladores customizados precisarao ser recriados em${C_RESET}"
    echo -e "${C_RED}    Window > Devices and Simulators${C_RESET}"
    echo -e "${C_DIM}  Use apenas para comecar do zero com os simuladores.${C_RESET}"
    echo ""
    if _ask "Apagar simuladores iOS?" "force_no"; then
        selected+=(ios_simulator_devices)
    fi

    # ------------------------------------------------------------------
    # PASSO C — Android SDK Platforms — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header C "Android SDK Platforms" high
    echo -e "${C_RED}  Apaga: ~/Library/Android/sdk/platforms/android-*${C_RESET}"
    echo -e "${C_RED}  - TODAS as versoes do SDK Android instaladas${C_RESET}"
    echo -e "${C_RED}  - Projetos que exigem versao especifica nao compilarao${C_RESET}"
    echo -e "${C_RED}  - Reinstalacao via Android Studio > SDK Manager${C_RESET}"
    echo -e "${C_DIM}  Use apenas para limpar e reinstalar o SDK do zero.${C_RESET}"
    echo ""
    if _ask "Apagar Android SDK Platforms?" "force_no"; then
        selected+=(android_sdk_old)
    fi

    # ------------------------------------------------------------------
    # Resumo e execucao
    # ------------------------------------------------------------------
    echo ""
    if [[ ${#selected[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}Nenhum passo selecionado. Limpeza cancelada.${C_RESET}"
        return 0
    fi

    echo -e "${C_BOLD}${C_CYAN}── Resumo do que sera apagado ──────────────────${C_RESET}"
    for cat in "${selected[@]}"; do
        echo -e "  ${C_DIM}•${C_RESET} $cat"
    done
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${C_YELLOW}[dry-run] Nada foi apagado.${C_RESET}"
        return 0
    fi

    local confirm_resp
    read -r -p "$(echo -e "${C_YELLOW}  Confirma a limpeza? [s/N]: ${C_RESET}")" confirm_resp </dev/tty
    if ! [[ "$confirm_resp" =~ ^[SsYy]$ ]]; then
        echo -e "${C_YELLOW}Cancelado.${C_RESET}"
        return 0
    fi

    echo ""
    echo -e "${C_BOLD}Iniciando limpeza...${C_RESET}"
    echo ""

    export SKIP_CATEGORY_CONFIRM=true
    _run_categories "${selected[@]}"
    unset SKIP_CATEGORY_CONFIRM
}

# ============ Category Analysis (shown before wizard) ============

_show_category_analysis() {
    local analyze_script="${SCRIPT_DIR}/analyze-categories.sh"
    # Inline category scan using the same lib already sourced
    local categories="caches logs npm_cache yarn_cache pnpm_store bun_cache expo_cache \
        turborepo_cache jest_cache playwright_cache cypress_cache \
        derived_data xcode_logs swiftpm_cache carthage_cache \
        pip_cache gem_cache ruby_bundler_cache nuget_cache \
        homebrew_cache nvm_cache vscode_cache trash \
        android_project_builds ios_project_builds"

    # Colors already defined
    local inner=$(( ${#C_RESET} > 0 ? 62 : 62 ))
    local W=64; local INN=$(( W - 2 ))
    local BAR=20

    _abar() {
        local b=$1 m=$2
        local f=0; [[ $m -gt 0 ]] && f=$(( b * BAR / m ))
        [[ $f -gt $BAR ]] && f=$BAR
        local e=$(( BAR - f ))
        local col=$C_GREEN
        [[ $f -ge $(( BAR * 35 / 100 )) ]] && col=$C_YELLOW
        [[ $f -ge $(( BAR * 70 / 100 )) ]] && col=$C_RED
        local bar="${col}"
        local i; for (( i=0; i<f; i++ )); do bar+='█'; done
        bar+="${C_DIM}"; for (( i=0; i<e; i++ )); do bar+='░'; done
        bar+="${C_RESET}"
        printf '%s' "$bar"
    }

    _aline() {
        local content="$1"
        local visible; visible=$(printf '%s' "$content" | sed 's/\x1b\[[0-9;]*m//g')
        local pad=$(( INN - ${#visible} )); [[ $pad -lt 0 ]] && pad=0
        printf '║%s%*s║\n' "$content" "$pad" ''
    }
    _atop() { printf '╔'; printf '═%.0s' $(seq 1 $INN); printf '╗\n'; }
    _asep() { printf '╠'; printf '═%.0s' $(seq 1 $INN); printf '╣\n'; }
    _abot() { printf '╚'; printf '═%.0s' $(seq 1 $INN); printf '╝\n'; }

    _ahuman() {
        local b=$1
        if   [[ $b -ge 1073741824 ]]; then awk -v b="$b" 'BEGIN{printf "%.1f GB",b/1073741824}'
        elif [[ $b -ge 1048576    ]]; then awk -v b="$b" 'BEGIN{printf "%.0f MB",b/1048576}'
        elif [[ $b -ge 1024       ]]; then awk -v b="$b" 'BEGIN{printf "%.0f KB",b/1024}'
        else echo "${b} B"; fi
    }

    # Show scanning message
    printf '╔'; printf '═%.0s' $(seq 1 $INN); printf '╗\n'
    _aline "  ${C_BOLD}${C_CYAN}Analisando categorias...${C_RESET}"
    printf '╚'; printf '═%.0s' $(seq 1 $INN); printf '╝\n'
    printf '\n'

    # Scan all categories (serial, with spinner)
    local TMPF; TMPF=$(mktemp)
    trap "rm -f '$TMPF'" RETURN

    local max_bytes=1
    local cat_results=()

    for cat in $categories; do
        local path; path=$(get_category_path "$cat" 2>/dev/null || true)
        [[ -z "$path" || ! -e "$path" ]] && continue
        local bytes
        bytes=$( { du -sk "$path" 2>/dev/null || true; } \
            | awk 'NR==1{print $1*1024; exit} END{if(NR==0) print 0}' )
        [[ -z "$bytes" ]] && bytes=0
        [[ $bytes -eq 0 ]] && continue
        cat_results+=("${bytes}|${cat}|${path}")
        [[ $bytes -gt $max_bytes ]] && max_bytes=$bytes
    done

    # Sort by size desc (bash 3 compatible bubble-ish via temp file)
    printf '%s\n' "${cat_results[@]}" | sort -t'|' -k1 -rn > "$TMPF"

    local grand=0

    # Group headers in order
    local groups="Sistema JS_TS Test iOS_Swift Python_Ruby Pkgs Misc"
    local group_printed=""

    _group_label() {
        case "$1" in
            Sistema)    echo "Sistema" ;;
            JS_TS)      echo "JS / TS" ;;
            Test)       echo "Build & Test" ;;
            iOS_Swift)  echo "iOS / Swift" ;;
            Python_Ruby) echo "Python · Ruby · .NET" ;;
            Pkgs)       echo "Pkg Managers" ;;
            Misc)       echo "Apps / Misc" ;;
        esac
    }

    _cat_group() {
        case "$1" in
            caches|logs|trash)                              echo "Sistema" ;;
            npm_cache|yarn_cache|pnpm_store|bun_cache|\
            expo_cache|turborepo_cache)                     echo "JS_TS" ;;
            jest_cache|playwright_cache|cypress_cache)      echo "Test" ;;
            derived_data|xcode_logs|swiftpm_cache|\
            carthage_cache|ios_project_builds)              echo "iOS_Swift" ;;
            pip_cache|gem_cache|ruby_bundler_cache|\
            nuget_cache)                                    echo "Python_Ruby" ;;
            homebrew_cache|nvm_cache)                       echo "Pkgs" ;;
            vscode_cache|android_project_builds)            echo "Misc" ;;
            *)                                              echo "Misc" ;;
        esac
    }

    printf '\r\033[2K'  # clear spinner line
    _atop
    _aline "  ${C_BOLD}${C_CYAN}Análise de Disco${C_RESET}  ${C_DIM}$(df -H / 2>/dev/null | awk 'NR==2{printf "%s livre de %s",$4,$2}')${C_RESET}"
    _asep

    for gkey in $groups; do
        local glabel; glabel=$(_group_label "$gkey")
        local group_rows="" group_bytes=0

        while IFS='|' read -r bytes cat path; do
            [[ "$(_cat_group "$cat")" != "$gkey" ]] && continue
            local h; h=$(_ahuman "$bytes")
            local bar; bar=$(_abar "$bytes" "$max_bytes")
            group_bytes=$(( group_bytes + bytes ))
            grand=$(( grand + bytes ))

            local lbl="$cat" lpad=20 spad=7
            [[ ${#lbl} -gt $lpad ]] && lbl="${lbl:0:$((lpad-1))}…"
            local row="  ${C_WHITE}$(printf '%-*s' "$lpad" "$lbl")${C_RESET}  ${bar}  $(printf '%*s' "$spad" "$h")"
            group_rows+="${row}"$'\n'
        done < "$TMPF"

        [[ -z "$group_rows" ]] && continue

        local gh; gh=$(_ahuman "$group_bytes")
        _aline "  ${C_BOLD}${C_BLUE}${glabel}${C_RESET}  ${C_DIM}${gh}${C_RESET}"
        while IFS= read -r row; do
            [[ -z "$row" ]] && continue
            _aline "$row"
        done <<< "$group_rows"
        _aline ""
    done

    _asep
    local grand_h; grand_h=$(_ahuman "$grand")
    _aline "  ${C_BOLD}${C_WHITE}Total identificado: ${C_YELLOW}${grand_h}${C_RESET}"
    _aline ""
    _abot
}

# ============ Main ============
main() {
    parse_arguments "$@"
    init_logging

    if ! validate_os; then exit 1; fi

    trap 'echo ""; echo "Interrompido."; exit 0' INT TERM

    _show_category_analysis

    echo ""
    local start_resp
    read -r -p "$(echo -e "${C_YELLOW}  Iniciar wizard de limpeza? [s/N]: ${C_RESET}")" start_resp </dev/tty
    if ! [[ "$start_resp" =~ ^[SsYy]$ ]]; then
        echo -e "${C_DIM}  Saindo sem limpar.${C_RESET}"
        echo ""
        exit 0
    fi

    run_wizard

    echo ""
    echo -e "${C_GREEN}${C_BOLD}Limpeza concluida.${C_RESET}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "${C_DIM}Log: $LOG_FILE${C_RESET}"
    fi
    echo ""
}

main "$@"
