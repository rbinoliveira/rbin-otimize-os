# Catálogo de Limpeza — rbin-otimize-os

---

## O que é apagado hoje ao rodar "Otimizar Espaço em Disco"

| Categoria | O que apaga | Regenerado automaticamente? |
|-----------|-------------|----------------------------|
| Caches gerais | `~/Library/Caches` — caches de qualquer app | Sim |
| Logs | `~/Library/Logs` — logs de apps e sistema | Sim |
| Temporários | `/tmp` | Sim |
| Lixeira | `~/.Trash` | Não (era descarte intencional) |
| Cache React Native | Metro bundler, `~/.rncache`, `/tmp/metro-*`, `/tmp/haste-map-*` | Sim, no próximo `npx start` |
| node_modules | Todas as pastas `node_modules` em `~/dev`, `~/projects`, `~/workspace`, `~/code`, `~/Documents`, `~/Desktop` | Sim, com `npm/yarn/pnpm install` |
| Docker VMs | `~/Library/Containers/com.docker.docker/Data/vms` | Sim, ao iniciar Docker |
| Docker volumes orphaned | Volumes de containers que não existem mais | Não — podem ter dados |
| Build artifacts | Pastas `dist`, `build`, `target`, `.next`, `.turbo`, `.parcel-cache`, `out`, `.nuxt`, `coverage`, `.nyc_output` dentro dos projetos | Sim, com `npm run build` etc. |
| Configs de apps deletados | `~/Library/Application Support` de apps que não existem mais em `/Applications` | Não (app foi removido) |
| Cache npm | `~/.npm` | Sim |
| Cache Expo | `~/.expo` | Sim |
| Cache VS Code | `~/Library/Application Support/Code/Cache` | Sim |
| Cache nvm | `~/.nvm/.cache` (só downloads em cache, não as versões Node instaladas) | Sim |
| Cache Yarn | `~/.yarn/cache` | Sim |
| Cache pip (Python) | `~/Library/Caches/pip` | Sim |
| Cache gem (Ruby) | `~/.gem/cache` | Sim |
| Cache Homebrew | `~/Library/Caches/Homebrew` — downloads antigos de fórmulas | Sim, ao reinstalar |

---

## O que pode ser apagado mas ainda não está (opcional)

Marque o que quiser habilitar.

| Categoria | O que apagaria | Tamanho típico | Risco |
|-----------|---------------|---------------|-------|
| Cache Flutter/Dart | `~/.pub-cache` | 500 MB–2 GB | Baixo — `flutter pub get` rebaixa |
| Cache Swift Package Manager | `~/Library/Caches/org.swift.swiftpm` | 200–500 MB | Baixo |
| Logs do Xcode/Simuladores | `~/Library/Logs/CoreSimulator`, `~/Library/Logs/DiagnosticReports` | 100–500 MB | Baixo — só logs |
| Cache Carthage | `~/Library/Caches/org.carthage.CarthageKit` | 200 MB–1 GB | Baixo |
| Cache Ruby Bundler | `~/.bundle/cache` | 100–500 MB | Baixo |
| Cache Turborepo global | `~/.turbo` | 500 MB–3 GB | Baixo — rebuild regera |
| Cache Jest | `/tmp/jest-*` | 100–500 MB | Baixo |
| Cache Playwright | `~/Library/Caches/ms-playwright` | 500 MB–2 GB | Baixo — requer rebaixar browsers |
| Cache Cypress | `~/.cache/Cypress` | 200 MB–1 GB | Baixo — requer rebaixar binário |
| Store pnpm | `~/.pnpm-store` | 1–5 GB | Médio — todos os projetos pnpm rebaixam |
| Cache Bun | `~/.bun/install/cache` | 200 MB–1 GB | Baixo |
| Builds Android dentro dos projetos | `~/dev/**/app/build` | 1–5 GB | Baixo — `./gradlew build` regera |
| Builds iOS dentro dos projetos | `~/dev/**/build/` (projetos RN/Flutter) | 1–3 GB | Baixo — rebuild regera |
| Emuladores Android (AVDs) | `~/.android/avd` | 2–10 GB por AVD | **Alto — apaga os emuladores, precisa recriar** |
| Versões antigas Android SDK | `~/Library/Android/sdk/platforms/android-<N>` | 1–3 GB por versão | **Alto — pode quebrar projetos antigos** |
| Simuladores iOS instalados | `~/Library/Developer/CoreSimulator/Devices` | 5–30 GB | **Alto — apaga dados dos simuladores** |
