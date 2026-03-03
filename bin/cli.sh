#!/usr/bin/env bash

# rbin-otimize-os — CLI entry point (installed via npm)
# Resolves the package root and delegates to run.sh

set -euo pipefail

# Resolve real path of this script, following symlinks (npm creates symlinks)
_resolve_dir() {
    local src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        local dir
        dir="$(cd "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        # Handle relative symlinks
        [[ "$src" != /* ]] && src="${dir}/${src}"
    done
    cd "$(dirname "$src")" && pwd
}

BIN_DIR="$(_resolve_dir)"
PACKAGE_ROOT="$(cd "${BIN_DIR}/.." && pwd)"
RUN_SCRIPT="${PACKAGE_ROOT}/run.sh"

if [[ ! -f "$RUN_SCRIPT" ]]; then
    echo "Erro: run.sh nao encontrado em $PACKAGE_ROOT" >&2
    exit 1
fi

chmod +x "$RUN_SCRIPT" 2>/dev/null || true

exec bash "$RUN_SCRIPT" "$@"
