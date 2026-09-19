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

O wizard guia por 18 passos agrupados por contexto,
mais 11 passos de alto risco (A-K: AVD, Simuladores iOS, SDK Platforms,
Runtimes iOS, componentes do Android SDK, Xcode Archives, versoes de
Node/Python/Ruby, Xcodes antigos, Time Machine, sistema, Downloads)
que sempre pedem confirmacao explicita.

Variaveis: STALE_PROJECT_DAYS=30  XCODE_DEVICE_SUPPORT_KEEP=2
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
    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"
    local resp
    read -r -n 1 -p "$(echo -e "${C_YELLOW}  ${prompt} [${hint}]: ${C_RESET}")" resp </dev/tty
    echo ""
    [[ -z "$resp" ]] && resp="$default"
    [[ "$resp" =~ ^[YySs]$ ]]
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
            android_avd|ios_simulator_devices|ios_simulator_runtimes|android_sdk_old|docker|\
            xcode_old_apps|tm_snapshots|system_caches)
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
    # PASSO 6 — Caches Xcode (tudo regenerado; nao quebra desenvolvimento)
    # ------------------------------------------------------------------
    _step_header 6 "Caches Xcode (DerivedData, DeviceSupport, SwiftPM, Carthage)"
    echo -e "${C_DIM}  Apaga: ~/Library/Developer/Xcode/DerivedData (indices e builds)${C_RESET}"
    echo -e "${C_DIM}         ~/Library/Developer/Xcode/iOS DeviceSupport (simbolos de debug)${C_RESET}"
    echo -e "${C_DIM}         ~/Library/Caches/org.swift.swiftpm${C_RESET}"
    echo -e "${C_DIM}         ~/Library/Caches/org.carthage.CarthageKit${C_RESET}"
    echo -e "${C_DIM}         ~/Library/Logs/CoreSimulator  ~/Library/Logs/DiagnosticReports${C_RESET}"
    echo -e "${C_GREEN}  - DeviceSupport mantem as 2 versoes de iOS mais recentes${C_RESET}"
    echo -e "${C_DIM}  Impacto: DerivedData e recriado sozinho — so o proximo build demora mais${C_RESET}"
    echo -e "${C_DIM}           Versoes antigas de DeviceSupport voltam ao reconectar o aparelho${C_RESET}"
    echo -e "${C_DIM}           Simuladores e projetos nao sao afetados${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(xcode xcode_device_support swiftpm_cache carthage_cache xcode_sim_logs)
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
    _step_header 9 "Docker (imagens, cache de build e volumes sem uso)"
    echo -e "${C_DIM}  Apaga: containers parados, redes orfas e cache de build${C_RESET}"
    echo -e "${C_DIM}         imagens sem container e sem uso ha mais de 30 dias${C_RESET}"
    echo -e "${C_DIM}         volumes Docker orphaned (containers que nao existem mais)${C_RESET}"
    echo -e "${C_GREEN}  - Imagens em uso e o disco da VM nao sao tocados${C_RESET}"
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
    # PASSO 11 — Gradle (versoes antigas)
    # ------------------------------------------------------------------
    _step_header 11 "Gradle (versoes antigas de caches, wrapper e daemon)"
    echo -e "${C_DIM}  Apaga: ~/.gradle/caches/<versao>  ~/.gradle/wrapper/dists/gradle-<versao>${C_RESET}"
    echo -e "${C_DIM}         ~/.gradle/daemon/<versao> + logs de daemon + jars-N/transforms-N antigos${C_RESET}"
    echo -e "${C_DIM}         ~/.gradle/jdks: arquivos .tar.gz ja extraidos e JDKs substituidos${C_RESET}"
    echo -e "${C_GREEN}  - Mantem a versao mais nova e as usadas pelo wrapper dos projetos em ~/dev${C_RESET}"
    echo -e "${C_GREEN}  - ~/.gradle/caches/modules-2 (dependencias) e gradle.properties nao sao tocados${C_RESET}"
    echo -e "${C_DIM}  Impacto: projeto com Gradle antigo fora de ~/dev re-baixa a distribuicao (~150 MB)${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(gradle_old_versions)
    fi

    # ------------------------------------------------------------------
    # PASSO 12 — Temporarios antigos
    # ------------------------------------------------------------------
    _step_header 12 "Temporarios antigos (\$TMPDIR e /private/tmp)"
    echo -e "${C_DIM}  Apaga: caches de Jest/Metro em \$TMPDIR (jest_*, metro-*, haste-map-*)${C_RESET}"
    echo -e "${C_DIM}         arquivos seus com mais de 3 dias em \$TMPDIR e /private/tmp${C_RESET}"
    echo -e "${C_GREEN}  - Sockets, .lock, .pid e arquivos recentes nao sao tocados${C_RESET}"
    echo -e "${C_DIM}  Impacto: nenhum — proximo teste/bundle recria o cache${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(tmp_old)
    fi

    # ------------------------------------------------------------------
    # PASSO 13 — Xcode extras
    # ------------------------------------------------------------------
    _step_header 13 "Xcode extras (DeviceSupport watch/tv/mac, previews, device logs)"
    echo -e "${C_DIM}  Apaga: watchOS/tvOS/macOS/visionOS DeviceSupport antigos${C_RESET}"
    echo -e "${C_DIM}         iOS Device Logs, UserData/Previews (SwiftUI), DocumentationCache${C_RESET}"
    echo -e "${C_DIM}         CoreSimulator/Caches + simuladores 'unavailable' (runtime removida)${C_RESET}"
    echo -e "${C_DIM}         XCTestDevices (clones de simulador de testes paralelos)${C_RESET}"
    echo -e "${C_GREEN}  - Mantem as 2 versoes mais novas de cada DeviceSupport${C_RESET}"
    echo -e "${C_GREEN}  - Previews so com Xcode fechado; cache de simulador so com Simulator fechado${C_RESET}"
    echo -e "${C_DIM}  Impacto: primeiro preview SwiftUI e primeiro boot de simulador mais lentos${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(xcode_extras)
    fi

    # ------------------------------------------------------------------
    # PASSO 14 — Android Studio extras
    # ------------------------------------------------------------------
    _step_header 14 "Android Studio / JetBrains extras (cache do SDK, snapshots, IDEs antigos)"
    echo -e "${C_DIM}  Apaga: ~/.android/cache  ~/.android/build-cache${C_RESET}"
    echo -e "${C_DIM}         snapshots de boot rapido dos AVDs (*.avd/snapshots)${C_RESET}"
    echo -e "${C_DIM}         config/cache/logs de versoes antigas do Android Studio e JetBrains${C_RESET}"
    echo -e "${C_GREEN}  - Os emuladores continuam; snapshots so sao apagados com emulador fechado${C_RESET}"
    echo -e "${C_GREEN}  - Mantem a versao mais nova de cada IDE/canal (estavel, Preview)${C_RESET}"
    echo -e "${C_DIM}  Impacto: proximo boot do emulador e 'frio' (~30s a mais)${C_RESET}"
    echo -e "${C_DIM}           configs de versoes antigas do IDE nao poderao mais ser importadas${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(android_extras)
    fi

    # ------------------------------------------------------------------
    # PASSO 15 — Caches de apps Chromium/Electron e editores
    # ------------------------------------------------------------------
    _step_header 15 "Caches de apps (Chrome, Brave, Slack, Notion, Cursor, VS Code…)"
    echo -e "${C_DIM}  Apaga: Cache, Code Cache, GPUCache, Dawn*/ShaderCache dos apps Chromium/Electron${C_RESET}"
    echo -e "${C_DIM}         CachedData antigo, CachedExtensionVSIXs e logs (+3 dias) de VS Code/Cursor${C_RESET}"
    echo -e "${C_DIM}         workspaceStorage de projetos cuja pasta nao existe mais${C_RESET}"
    echo -e "${C_DIM}         caches de apps da App Store (~/Library/Containers/*/Data/Library/Caches)${C_RESET}"
    echo -e "${C_DIM}  Obs: o macOS pode perguntar se o Terminal pode acessar dados de outros apps${C_RESET}"
    echo -e "${C_GREEN}  - Perfis, senhas, favoritos, cookies e extensoes nao sao tocados${C_RESET}"
    echo -e "${C_DIM}  Impacto: apps abrem um pouco mais devagar na primeira vez${C_RESET}"
    echo -e "${C_DIM}           (de preferencia feche os apps antes)${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(electron_caches editor_caches container_caches)
    fi

    # ------------------------------------------------------------------
    # PASSO 16 — Outros caches de ferramentas
    # ------------------------------------------------------------------
    _step_header 16 "Outros caches (Prisma, Puppeteer, Firebase, uv, Cargo, CocoaPods…)"
    echo -e "${C_DIM}  Apaga: ~/.yarn/berry/cache  ~/.cache/node/corepack${C_RESET}"
    echo -e "${C_DIM}         ~/.cache/{puppeteer,prisma,firebase/emulators,uv,pre-commit,node-gyp}${C_RESET}"
    echo -e "${C_DIM}         ~/.node-gyp ~/.electron-gyp ~/.cargo/registry/src ~/.cocoapods/repos/trunk${C_RESET}"
    echo -e "${C_DIM}         firmwares .ipsw baixados em ~/Library/iTunes${C_RESET}"
    echo -e "${C_GREEN}  - Repos privados do CocoaPods e modelos de IA (huggingface/ollama) ficam${C_RESET}"
    echo -e "${C_DIM}  Impacto: re-download sob demanda (Puppeteer: npx puppeteer browsers install)${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(misc_dev_caches ios_firmware)
    fi

    # ------------------------------------------------------------------
    # PASSO 17 — Homebrew autoremove
    # ------------------------------------------------------------------
    _step_header 17 "Homebrew (dependencias orfas)"
    echo -e "${C_DIM}  Executa: brew autoremove${C_RESET}"
    echo -e "${C_GREEN}  - So remove formulas instaladas como dependencia que nada mais usa${C_RESET}"
    echo -e "${C_DIM}  Impacto: baixo — formulas que voce instalou direto nao sao tocadas${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(homebrew_autoremove)
    fi

    # ------------------------------------------------------------------
    # PASSO 18 — Dependencias de projetos parados
    # ------------------------------------------------------------------
    _step_header 18 "Dependencias de projetos parados ha +${STALE_PROJECT_DAYS} dias"
    echo -e "${C_DIM}  Apaga, em ~/dev ~/projects ~/workspace ~/code:${C_RESET}"
    echo -e "${C_DIM}         Pods/ .venv/ .gradle/ .cxx/ .dart_tool/ .nx/ .angular/ .svelte-kit/${C_RESET}"
    echo -e "${C_DIM}         __pycache__/ .pytest_cache/ .mypy_cache/ .ruff_cache/${C_RESET}"
    echo -e "${C_GREEN}  - So em projetos sem nenhum arquivo alterado nos ultimos ${STALE_PROJECT_DAYS} dias${C_RESET}"
    echo -e "${C_DIM}  Impacto: ao voltar ao projeto rode pod install / pip install -r ... / etc.${C_RESET}"
    echo -e "${C_DIM}           pacotes instalados a mao num .venv (fora do requirements) se perdem${C_RESET}"
    if _ask "Limpar?"; then
        selected+=(stale_project_deps)
    fi

    # ------------------------------------------------------------------
    # PASSO A — Emuladores Android (AVD) — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header A "Emuladores Android (AVDs)" high
    echo -e "${C_RED}  Apaga: ~/.android/avd — emuladores Android${C_RESET}"
    echo -e "${C_GREEN}  - 1 emulador e sempre preservado (o usado mais recentemente)${C_RESET}"
    echo -e "${C_RED}  - Os demais sao removidos permanentemente${C_RESET}"
    echo -e "${C_RED}  - Apps instalados nos emuladores removidos serao perdidos${C_RESET}"
    echo -e "${C_RED}  - Precisara recriar os AVDs no Android Studio > Device Manager${C_RESET}"
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
    echo -e "${C_GREEN}  - 1 simulador e sempre preservado (iPhone do iOS mais recente)${C_RESET}"
    echo -e "${C_GREEN}    Ele e apenas resetado (erase) — continua utilizavel${C_RESET}"
    echo -e "${C_RED}  - Os demais simuladores sao removidos permanentemente${C_RESET}"
    echo -e "${C_RED}  - Apps instalados nos simuladores serao perdidos${C_RESET}"
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
    echo -e "${C_RED}  Apaga: \$ANDROID_SDK_ROOT/platforms ou ~/Library/Android/sdk/platforms${C_RESET}"
    echo -e "${C_GREEN}  - A plataforma mais recente e sempre preservada${C_RESET}"
    echo -e "${C_RED}  - As demais versoes do SDK sao removidas${C_RESET}"
    echo -e "${C_RED}  - Projetos que exigem versao especifica nao compilarao${C_RESET}"
    echo -e "${C_RED}  - Reinstalacao via Android Studio > SDK Manager${C_RESET}"
    echo -e "${C_DIM}  Use apenas para limpar e reinstalar o SDK do zero.${C_RESET}"
    echo ""
    if _ask "Apagar Android SDK Platforms?" "force_no"; then
        selected+=(android_sdk_old)
    fi

    # ------------------------------------------------------------------
    # PASSO D — Runtimes de simulador iOS — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header D "Runtimes de simulador iOS" high
    echo -e "${C_RED}  Apaga: runtimes baixadas (/Library/Developer/CoreSimulator/Volumes)${C_RESET}"
    echo -e "${C_GREEN}  - A runtime mais recente e sempre preservada${C_RESET}"
    echo -e "${C_GREEN}  - Runtimes com simulador criado em cima tambem ficam${C_RESET}"
    echo -e "${C_RED}  - As demais sao removidas via 'simctl runtime delete'${C_RESET}"
    echo -e "${C_RED}  - Cada runtime pesa ~8 GB e o download de volta e demorado${C_RESET}"
    echo -e "${C_DIM}  Costuma ser o maior item de disco de quem atualiza o Xcode.${C_RESET}"
    echo -e "${C_DIM}  Reinstalacao: Xcode > Settings > Components.${C_RESET}"
    echo ""
    if _ask "Apagar runtimes de simulador sem uso?" "force_no"; then
        selected+=(ios_simulator_runtimes)
    fi

    # ------------------------------------------------------------------
    # PASSO E — Android SDK: componentes sem uso — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header E "Android SDK: system images, NDKs e build-tools sem uso" high
    echo -e "${C_RED}  Apaga: system-images que nenhum AVD usa${C_RESET}"
    echo -e "${C_RED}         NDKs antigos e build-tools antigos${C_RESET}"
    echo -e "${C_GREEN}  - Fica a system image de maior API e as usadas por AVDs${C_RESET}"
    echo -e "${C_GREEN}  - Fica o NDK mais novo e os fixados em ndkVersion nos projetos de ~/dev${C_RESET}"
    echo -e "${C_GREEN}  - Ficam as 2 build-tools mais novas e as fixadas em buildToolsVersion${C_RESET}"
    echo -e "${C_RED}  - Projetos fora de ~/dev com NDK antigo vao re-baixar (~1-2 GB cada)${C_RESET}"
    echo -e "${C_RED}  - Criar AVD com imagem antiga exige baixar de novo no SDK Manager${C_RESET}"
    echo ""
    if _ask "Apagar componentes do Android SDK sem uso?" "force_no"; then
        selected+=(android_sdk_unused)
    fi

    # ------------------------------------------------------------------
    # PASSO F — Xcode Archives antigos — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header F "Xcode Archives antigos" high
    echo -e "${C_RED}  Apaga: ~/Library/Developer/Xcode/Archives com mais de 90 dias${C_RESET}"
    echo -e "${C_GREEN}  - O archive mais recente de cada app e sempre preservado${C_RESET}"
    echo -e "${C_RED}  - Archives guardam os dSYMs: crashes de versoes antigas publicadas${C_RESET}"
    echo -e "${C_RED}    nao poderao mais ser simbolizados (a menos que estejam no Crashlytics/Sentry)${C_RESET}"
    echo -e "${C_RED}  - Nao sera possivel reenviar builds antigos para a App Store${C_RESET}"
    echo ""
    if _ask "Apagar Xcode Archives antigos?" "force_no"; then
        selected+=(xcode_archives_old)
    fi

    # ------------------------------------------------------------------
    # PASSO G — Versoes antigas de Node/Python/Ruby — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header G "Versoes antigas de Node, Python e Ruby" high
    echo -e "${C_RED}  Apaga: versoes em nvm, fnm, volta, mise, asdf, pyenv, rbenv, chruby${C_RESET}"
    echo -e "${C_GREEN}  - Fica a versao mais nova de cada gerenciador${C_RESET}"
    echo -e "${C_GREEN}  - Ficam as fixadas em .nvmrc/.node-version/.python-version/.ruby-version/${C_RESET}"
    echo -e "${C_GREEN}    .tool-versions/mise.toml dos projetos e as globais (nvm default, pyenv global)${C_RESET}"
    echo -e "${C_GREEN}  - Virtualenvs do pyenv e versoes com processo rodando nao sao tocados${C_RESET}"
    echo -e "${C_RED}  - Pacotes globais (npm -g, pip, gems) das versoes apagadas se perdem${C_RESET}"
    echo -e "${C_RED}  - Projeto sem arquivo de versao que dependia de versao antiga quebra${C_RESET}"
    echo ""
    if _ask "Apagar versoes antigas de runtimes?" "force_no"; then
        selected+=(runtime_old_versions)
    fi

    # ------------------------------------------------------------------
    # PASSO H — Xcodes antigos — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header H "Xcodes antigos em /Applications" high
    echo -e "${C_RED}  Apaga: /Applications/Xcode*.app extras (cada um tem 10+ GB)${C_RESET}"
    echo -e "${C_GREEN}  - Fica o Xcode selecionado (xcode-select -p) e o de versao mais nova${C_RESET}"
    echo -e "${C_RED}  - Nao sera possivel compilar com o SDK/Swift das versoes removidas${C_RESET}"
    echo -e "${C_DIM}  Pode pedir senha (sudo) se o Xcode veio da App Store.${C_RESET}"
    echo ""
    if _ask "Apagar Xcodes antigos?" "force_no"; then
        selected+=(xcode_old_apps)
    fi

    # ------------------------------------------------------------------
    # PASSO I — Snapshots locais do Time Machine — ALTO RISCO
    # ------------------------------------------------------------------
    local tm_count; tm_count=$(list_tm_local_snapshots | grep -c . || true)
    _step_header I "Snapshots locais do Time Machine (${tm_count} encontrados)" high
    echo -e "${C_RED}  Apaga: snapshots APFS locais do disco de boot (tmutil deletelocalsnapshots)${C_RESET}"
    echo -e "${C_RED}  - Perde os pontos de restauracao locais (os backups no disco externo ficam)${C_RESET}"
    echo -e "${C_DIM}  O macOS ja apaga sozinho quando falta espaco, mas o espaco aparece como${C_RESET}"
    echo -e "${C_DIM}  'purgeable' e alguns apps/instaladores nao contam com ele. Pede senha (sudo).${C_RESET}"
    echo ""
    if _ask "Apagar snapshots locais do Time Machine?" "force_no"; then
        selected+=(tm_snapshots)
    fi

    # ------------------------------------------------------------------
    # PASSO J — Caches e logs do sistema — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header J "Caches e logs do sistema (sudo)" high
    echo -e "${C_RED}  Apaga: /Library/Caches/* (exceto com.apple.*)${C_RESET}"
    echo -e "${C_RED}         /Library/Logs/DiagnosticReports  logs .gz/.bz2 em /private/var/log${C_RESET}"
    echo -e "${C_RED}  - Crash reports do sistema somem (nao da mais para enviar a Apple/devs)${C_RESET}"
    echo -e "${C_RED}  - Apps/atualizadores de terceiros regeneram o cache (1a execucao mais lenta)${C_RESET}"
    echo -e "${C_DIM}  Pede senha (sudo).${C_RESET}"
    echo ""
    if _ask "Apagar caches e logs do sistema?" "force_no"; then
        selected+=(system_caches)
    fi

    # ------------------------------------------------------------------
    # PASSO K — Instaladores antigos em Downloads — ALTO RISCO
    # ------------------------------------------------------------------
    _step_header K "Instaladores antigos em ~/Downloads" high
    echo -e "${C_RED}  Apaga: .dmg .pkg .xip .iso em ~/Downloads com mais de 30 dias${C_RESET}"
    local dl_line dl_n=0
    while IFS= read -r dl_line; do
        [[ -z "$dl_line" ]] && continue
        dl_n=$((dl_n + 1))
        [[ $dl_n -le 15 ]] && echo -e "${C_DIM}    - ${dl_line##*/}${C_RESET}"
    done < <(list_extra_category_targets downloads_installers)
    [[ $dl_n -gt 15 ]] && echo -e "${C_DIM}    ... e mais $((dl_n - 15))${C_RESET}"
    [[ $dl_n -eq 0 ]] && echo -e "${C_GREEN}  - Nenhum encontrado${C_RESET}"
    echo -e "${C_RED}  - Sao arquivos seus: instaladores de versoes antigas podem nao existir mais online${C_RESET}"
    echo ""
    if [[ $dl_n -gt 0 ]] && _ask "Apagar esses instaladores?" "force_no"; then
        selected+=(downloads_installers)
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
    read -r -n 1 -p "$(echo -e "${C_YELLOW}  Confirma a limpeza? [y/N]: ${C_RESET}")" confirm_resp </dev/tty
    echo ""
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
        android_project_builds ios_project_builds \
        gradle_old_versions tmp_old xcode_extras android_extras \
        electron_caches editor_caches misc_dev_caches ios_firmware \
        android_sdk_unused xcode_archives_old container_caches stale_project_deps \
        runtime_old_versions xcode_old_apps system_caches downloads_installers"

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
        local path bytes
        if is_extra_cleanup_category "$cat"; then
            path="(varios)"
            bytes=$(extra_category_bytes "$cat")
        else
            path=$(get_category_path "$cat" 2>/dev/null || true)
            [[ -z "$path" || ! -e "$path" ]] && continue
            bytes=$( { du -sk "$path" 2>/dev/null || true; } \
                | awk 'NR==1{print $1*1024; exit} END{if(NR==0) print 0}' )
        fi
        [[ -z "$bytes" ]] && bytes=0
        [[ $bytes -eq 0 ]] && continue
        cat_results+=("${bytes}|${cat}|${path}")
        [[ $bytes -gt $max_bytes ]] && max_bytes=$bytes
    done

    # Sort by size desc (bash 3 compatible bubble-ish via temp file)
    printf '%s\n' "${cat_results[@]}" | sort -t'|' -k1 -rn > "$TMPF"

    local grand=0

    # Group headers in order
    local groups="Sistema JS_TS Test iOS_Swift Android Python_Ruby Pkgs Misc"
    local group_printed=""

    _group_label() {
        case "$1" in
            Sistema)    echo "Sistema" ;;
            JS_TS)      echo "JS / TS" ;;
            Test)       echo "Build & Test" ;;
            iOS_Swift)  echo "iOS / Swift" ;;
            Android)    echo "Android" ;;
            Python_Ruby) echo "Python · Ruby · .NET" ;;
            Pkgs)       echo "Pkg Managers" ;;
            Misc)       echo "Apps / Misc" ;;
        esac
    }

    _cat_group() {
        case "$1" in
            caches|logs|trash|tmp_old|system_caches|\
            downloads_installers)                           echo "Sistema" ;;
            npm_cache|yarn_cache|pnpm_store|bun_cache|\
            expo_cache|turborepo_cache)                     echo "JS_TS" ;;
            jest_cache|playwright_cache|cypress_cache)      echo "Test" ;;
            derived_data|xcode_logs|swiftpm_cache|\
            carthage_cache|ios_project_builds|\
            xcode_extras|ios_firmware|xcode_archives_old|\
            xcode_old_apps)                                 echo "iOS_Swift" ;;
            android_project_builds|gradle_old_versions|\
            android_extras|android_sdk_unused)              echo "Android" ;;
            pip_cache|gem_cache|ruby_bundler_cache|\
            nuget_cache)                                    echo "Python_Ruby" ;;
            homebrew_cache|nvm_cache|misc_dev_caches|\
            runtime_old_versions|stale_project_deps)        echo "Pkgs" ;;
            vscode_cache|electron_caches|editor_caches|\
            container_caches)                               echo "Misc" ;;
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

    # Itens grandes que o wizard nunca apaga: so para voce decidir manualmente.
    local info_rows="" info_path info_label info_bytes
    while IFS='|' read -r info_label info_path; do
        [[ -e "$info_path" ]] || continue
        info_bytes=$( { du -sk "$info_path" 2>/dev/null || true; } | awk 'NR==1{print $1*1024; exit} END{if(NR==0) print 0}')
        [[ "$info_bytes" =~ ^[0-9]+$ && $info_bytes -gt 0 ]] || continue
        info_rows+="  ${C_WHITE}$(printf '%-24s' "$info_label")${C_RESET}  $(printf '%9s' "$(_ahuman "$info_bytes")")"$'\n'
    done <<INFO
Backups de iPhone|${HOME}/Library/Application Support/MobileSync/Backup
Modelos HuggingFace|${HOME}/.cache/huggingface
Modelos Ollama|${HOME}/.ollama/models
Modelos LM Studio|${HOME}/.lmstudio/models
Go modcache|${HOME}/go/pkg/mod
Maven (~/.m2)|${HOME}/.m2/repository
Docker Desktop (VM)|${HOME}/Library/Containers/com.docker.docker/Data/vms
OrbStack|${HOME}/.orbstack
INFO
    if [[ -n "$info_rows" ]]; then
        _asep
        _aline "  ${C_BOLD}${C_BLUE}Nao apagado (so informativo)${C_RESET}"
        while IFS= read -r row; do
            [[ -z "$row" ]] && continue
            _aline "$row"
        done <<< "$info_rows"
        _aline ""
    fi

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
    read -r -n 1 -p "$(echo -e "${C_YELLOW}  Iniciar wizard de limpeza? [y/N]: ${C_RESET}")" start_resp </dev/tty
    echo ""
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
