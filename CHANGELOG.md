# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Limpeza de disco (macOS): 7 passos novos no wizard e 2 de alto risco, sem mudar os existentes.
  - Passo 11: versões antigas do Gradle (preserva a mais nova, as do wrapper dos projetos e as com daemon rodando).
  - Passo 12: temporários antigos em `$TMPDIR` e `/private/tmp` (+3 dias) e caches de Jest/Metro no `$TMPDIR`.
  - Passo 13: extras do Xcode (DeviceSupport watch/tv/mac/visionOS, previews SwiftUI, device logs, simuladores indisponíveis).
  - Passo 14: extras do Android Studio (cache do SDK, versões antigas do IDE).
  - Passo 15: caches de apps Chromium/Electron e de editores VS Code/Cursor (inclui `workspaceStorage` de projetos apagados).
  - Passo 16: outros caches de ferramentas (Prisma, Puppeteer, Firebase, uv, Cargo, CocoaPods trunk) e firmwares `.ipsw`.
  - Passo 17: `brew autoremove`.
  - Passo E (alto risco): system images, NDKs e build-tools do Android SDK sem uso.
  - Passo F (alto risco): Xcode Archives com mais de 90 dias (preserva o mais recente de cada app).
- Painel de análise mostra o tamanho das categorias novas e um grupo "Android".
- Passo 18: dependências regeneráveis (Pods, .venv, .gradle, .cxx, .nx, caches Python…) de projetos parados há +30 dias (`STALE_PROJECT_DAYS`).
- Passos de alto risco G–K: versões antigas de Node/Python/Ruby (nvm, fnm, volta, mise, asdf, pyenv, rbenv), Xcodes antigos, snapshots locais do Time Machine, caches/logs do sistema (sudo) e instaladores antigos em ~/Downloads.
- Passos 11, 13, 14, 15 e 16 ampliados: JDKs do Gradle, XCTestDevices, snapshots de AVD, IDEs JetBrains antigos, caches de apps sandboxed, cache do Yarn Berry e Corepack.
- Painel mostra itens grandes que nunca são apagados (backups de iPhone, modelos de IA, Go/Maven, VM do Docker) como informativo.

### Fixed

- `temp` no macOS não apagava nada (`/tmp` é link para `/private/tmp`); agora limpa arquivos do usuário com +1 dia.
- `jest_cache` e o Metro em `react_native` passam a procurar também no `$TMPDIR`, onde esses caches ficam no macOS.
- Painel de análise usava caminhos errados para `pnpm_store` e `cypress_cache` no macOS.

## [2.0.2] - 2025-03-09

### Added

- Comando `rbin-otimize-os init` para configurar o projeto (pastas e permissões dos scripts).
- Script `postinstall` no npm: após `npm install` o setup é executado automaticamente via `run.sh init`.

### Changed

- Ajuda (`--help`) atualizada com o comando `init`.
- README (PT/EN) documentando o fluxo pós-instalação e o comando `init`.

---

## [2.0.1]

Versão anterior (sem changelog detalhado).
