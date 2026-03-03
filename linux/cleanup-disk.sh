#!/usr/bin/env bash

# Linux Disk Cleanup Script
# Version: 2.0.0
# Description: Wizard interativo de limpeza de disco

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
    C_DIM=$(tput dim 2>/dev/null || echo '')
    C_WHITE=$(tput setaf 7)
else
    C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
    C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_WHITE='\033[0;37m'
fi

# ============ Logging ============
init_logging() {
    if [[ -w "/var/log" ]] && sudo -n true 2>/dev/null; then
        sudo mkdir -p /var/log/os-optimize 2>/dev/null && LOG_DIR="/var/log/os-optimize" || true
    fi
    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        chmod 755 "$LOG_DIR" 2>/dev/null || true
        local timestamp=$(date +%Y%m%d-%H%M%S)
        LOG_FILE="${LOG_DIR}/cleanup-disk-${timestamp}.log"
        {
            echo "=========================================="
            echo "Linux Disk Cleanup Wizard - Log"
            echo "=========================================="
            echo "Timestamp: $(date)"
            echo "Kernel: $(uname -r 2>/dev/null || echo 'unknown')"
            echo "Distro: $(grep "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
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
Linux Disk Cleanup Wizard v$SCRIPT_VERSION

Uso: $0 [OPCOES]

Opcoes:
    --dry-run, -n    Simula sem apagar nada
    --verbose, -v    Saida detalhada
    --quiet, -q      Saida minima
    --force, -f      Pula confirmacoes (exceto passos de alto risco)
    --all-users      Limpa todos os usuarios do sistema (requer sudo)
    --min-age=N      So limpa arquivos mais velhos que N dias
    -h, --help       Esta ajuda

O wizard guia por passos agrupados por contexto,
com passos de alto risco (AVD Android) sempre pedindo
confirmacao explicita independente do --force.
EOF
}

# ============ Helpers ============

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

_run_categories() {
    local -a cats=("$@")
    local cleaned=0 failed=0 total=${#cats[@]}
    local i=0
    for cat in "${cats[@]}"; do
        i=$((i+1))
        echo -e "  ${C_DIM}[$i/$total]${C_RESET} Limpando ${C_WHITE}${cat}${C_RESET}..."
        set +e
        case "$cat" in
            android_avd|android_sdk_old)
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

# Detecta gerenciadores de pacotes disponiveis
_detect_pkg_managers() {
    local -a available=()
    command -v apt-get >/dev/null 2>&1 && available+=(apt)
    command -v yum    >/dev/null 2>&1 && available+=(yum)
    command -v dnf    >/dev/null 2>&1 && available+=(yum)  # dnf usa mesma categoria
    command -v pacman >/dev/null 2>&1 && available+=(pacman)
    command -v snap   >/dev/null 2>&1 && available+=(snap)
    printf '%s\n' "${available[@]}" | sort -u
}

# ============ Wizard ============
run_wizard() {
    local -a selected=()

    echo ""
    echo -e "${C_BOLD}${C_CYAN}  Wizard de Limpeza de Disco — Linux${C_RESET}"
    echo -e "${C_DIM}  Responda cada passo. 'N' pula o passo sem apagar nada.${C_RESET}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${C_YELLOW}[dry-run] Nenhum arquivo sera apagado.${C_RESET}"
    fi

    # ------------------------------------------------------------------
    # PASSO 1 — Limpeza geral
    # ------------------------------------------------------------------
    _step_header 1 "Limpeza geral (caches, logs, temporarios, lixeira)"
    echo -e "${C_DIM}  Apaga: ~/.cache  /var/log (logs antigos)  /tmp  ~/.local/share/Trash${C_RESET}"
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
    echo -e "${C_DIM}         dentro de ~/dev e similares${C_RESET}"
    echo -e "${C_DIM}         + app/build Android dentro dos projetos${C_RESET}"
    echo -e "${C_DIM}  Impacto: precisa rodar npm run build / gradlew build para recriar${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(build_artifacts android_project_builds)
    fi

    # ------------------------------------------------------------------
    # PASSO 4 — Ferramentas de teste
    # ------------------------------------------------------------------
    _step_header 4 "Caches de teste (Jest, Playwright, Cypress)"
    echo -e "${C_DIM}  Apaga: /tmp/jest-*  ~/.cache/ms-playwright  ~/.cache/Cypress${C_RESET}"
    echo -e "${C_DIM}  Impacto: proximo 'npx playwright install' / 'npx cypress install'${C_RESET}"
    echo -e "${C_DIM}           vai re-baixar os binarios dos browsers${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(jest_cache playwright_cache cypress_cache)
    fi

    # ------------------------------------------------------------------
    # PASSO 5 — Python, Ruby, .NET
    # ------------------------------------------------------------------
    _step_header 5 "Caches Python, Ruby e .NET (pip, gem, bundler, NuGet)"
    echo -e "${C_DIM}  Apaga: ~/.cache/pip  ~/.gem/cache  ~/.bundle/cache  ~/.nuget  ~/.dotnet${C_RESET}"
    echo -e "${C_DIM}  Impacto: proximas instalacoes serao mais lentas (re-download)${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(pip_cache gem_cache ruby_bundler_cache nuget_cache dotnet_cache)
    fi

    # ------------------------------------------------------------------
    # PASSO 6 — node_modules dos projetos
    # ------------------------------------------------------------------
    _step_header 6 "node_modules dos projetos em ~/dev"
    echo -e "${C_DIM}  Apaga: todas as pastas node_modules/ encontradas em${C_RESET}"
    echo -e "${C_DIM}         ~/dev ~/projects ~/workspace ~/code ~/Documents ~/Desktop${C_RESET}"
    echo -e "${C_DIM}  Impacto: precisa rodar npm/yarn/pnpm install em cada projeto${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(node_modules)
    fi

    # ------------------------------------------------------------------
    # PASSO 7 — Apps desinstalados e cache VS Code
    # ------------------------------------------------------------------
    _step_header 7 "Configs de apps desinstalados e cache VS Code"
    echo -e "${C_DIM}  Apaga: ~/.config/<app> de apps nao instalados${C_RESET}"
    echo -e "${C_DIM}         ~/.config/Code/Cache (VS Code)${C_RESET}"
    echo -e "${C_DIM}         ~/.nvm/.cache (downloads do nvm — versoes Node mantidas)${C_RESET}"
    echo -e "${C_DIM}  Impacto: baixo — VS Code recria cache sozinho${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(orphaned_apps vscode_cache nvm_cache)
    fi

    # ------------------------------------------------------------------
    # PASSO 8 — Docker
    # ------------------------------------------------------------------
    _step_header 8 "Docker (volumes nao usados)"
    echo -e "${C_DIM}  Apaga: /var/lib/docker (VMs)  volumes Docker orphaned${C_RESET}"
    echo -e "${C_DIM}  Impacto: medio — volumes podem ter dados de containers parados${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(docker volumes)
    fi

    # ------------------------------------------------------------------
    # PASSO 9 — Gerenciadores de pacotes do sistema
    # ------------------------------------------------------------------
    _step_header 9 "Cache de gerenciadores de pacotes do sistema"
    local -a pkg_cats=()
    local pkg_info=""
    while IFS= read -r pm; do
        case "$pm" in
            apt)    pkg_cats+=(apt);    pkg_info+=" apt(/var/cache/apt)" ;;
            yum)    pkg_cats+=(yum);    pkg_info+=" yum/dnf(/var/cache/yum)" ;;
            pacman) pkg_cats+=(pacman); pkg_info+=" pacman(/var/cache/pacman/pkg)" ;;
            snap)   pkg_cats+=(snap);   pkg_info+=" snap(/var/lib/snapd/cache)" ;;
        esac
    done < <(_detect_pkg_managers)

    if [[ ${#pkg_cats[@]} -eq 0 ]]; then
        echo -e "${C_DIM}  Nenhum gerenciador de pacotes detectado. Pulando.${C_RESET}"
    else
        echo -e "${C_DIM}  Detectados:${pkg_info}${C_RESET}"
        echo -e "${C_DIM}  Impacto: pacotes serao re-baixados na proxima instalacao${C_RESET}"
        if _ask "Limpar?"; then
            selected+=("${pkg_cats[@]}")
        fi
    fi

    # ------------------------------------------------------------------
    # PASSO 10 — Flutter
    # ------------------------------------------------------------------
    _step_header 10 "Cache Flutter/Dart"
    echo -e "${C_DIM}  Apaga: ~/.pub-cache${C_RESET}"
    echo -e "${C_DIM}  Impacto: 'flutter pub get' re-baixa os pacotes${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(flutter_cache)
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
    # PASSO B — Android SDK Platforms — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header B "Android SDK Platforms" high
    echo -e "${C_RED}  Apaga: ~/Android/Sdk/platforms/android-* (caminho padrao Linux)${C_RESET}"
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

# ============ Main ============
main() {
    parse_arguments "$@"
    init_logging

    if ! validate_os; then exit 1; fi

    trap 'echo ""; echo "Interrompido."; exit 0' INT TERM

    run_wizard

    echo ""
    echo -e "${C_GREEN}${C_BOLD}Limpeza concluida.${C_RESET}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "${C_DIM}Log: $LOG_FILE${C_RESET}"
    fi
    echo ""
}

main "$@"
