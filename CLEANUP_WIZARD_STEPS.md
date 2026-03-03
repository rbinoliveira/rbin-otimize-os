# Sugestão de Fluxo de Perguntas ao Usuário

Quando o usuário escolhe "Otimizar Espaço em Disco", em vez de mostrar uma lista enorme de categorias,
poderia guiar com perguntas agrupadas por contexto — do mais seguro ao mais impactante.

---

## Passo 1 — Limpeza geral (sempre seguro)

**Pergunta:** "Limpar caches gerais, logs e temporários?"

O que apaga:
- `~/Library/Caches` — caches de qualquer app
- `~/Library/Logs` — logs de apps e sistema
- `/tmp` — temporários do sistema
- `~/.Trash` — Lixeira

**Impacto:** nenhum. Tudo é regenerado automaticamente.

---

## Passo 2 — Caches de desenvolvimento JS/TS

**Pergunta:** "Limpar caches de ferramentas JS/TS (npm, yarn, pnpm, bun, expo, turbo)?"

O que apaga:
- `~/.npm` — cache npm
- `~/.yarn/cache` — cache yarn
- `~/.pnpm-store` — store global pnpm (todos os projetos rebaixam pacotes)
- `~/.bun/install/cache` — cache bun
- `~/.expo` — cache Expo CLI
- `~/.turbo` — cache global Turborepo
- Metro bundler / `~/.rncache` / `/tmp/metro-*` — cache React Native

**Impacto:** próximos `npm install`, `yarn install`, etc. serão mais lentos (re-download). Nada quebra.

---

## Passo 3 — Build outputs dos projetos

**Pergunta:** "Apagar outputs de build dentro dos seus projetos (dist, build, .next, .turbo, coverage…)?"

O que apaga:
- Pastas `dist/`, `build/`, `target/`, `.next/`, `.nuxt/`, `.output/`, `coverage/`, `.nyc_output/` dentro de `~/dev` e similares
- Pastas `app/build` dentro de projetos Android
- Pastas `ios/build` e `Build/Products` dentro de projetos React Native / Flutter

**Impacto:** precisa rodar `npm run build` / `./gradlew build` / build via Xcode para recriar. Nada permanente.

---

## Passo 4 — Caches de ferramentas de teste

**Pergunta:** "Limpar caches de Jest, Playwright e Cypress?"

O que apaga:
- `/tmp/jest-*` — cache do Jest
- `~/Library/Caches/ms-playwright` — browsers baixados pelo Playwright
- `~/.cache/Cypress` — binário do Cypress

**Impacto:** próximo `npx playwright install` / `npx cypress install` vai re-baixar os binários (pode demorar).

---

## Passo 5 — Caches Python, Ruby e .NET

**Pergunta:** "Limpar caches de pip, gem, bundler e NuGet?"

O que apaga:
- `~/Library/Caches/pip` — cache pip Python
- `~/.gem/cache` — cache gem Ruby
- `~/.bundle/cache` — cache Bundler Ruby
- `~/.nuget` — cache NuGet .NET
- `~/.dotnet` — cache runtime .NET

**Impacto:** próximas instalações de pacotes serão mais lentas (re-download). Nada quebra.

---

## Passo 6 — Caches iOS / Swift (não quebra desenvolvimento)

**Pergunta:** "Limpar caches do Swift Package Manager, Carthage e logs do Xcode/Simuladores?"

O que apaga:
- `~/Library/Caches/org.swift.swiftpm` — cache do Swift Package Manager
- `~/Library/Caches/org.carthage.CarthageKit` — cache do Carthage
- `~/Library/Logs/CoreSimulator` — logs dos simuladores
- `~/Library/Logs/DiagnosticReports` — crash reports

**Impacto:** próximo build via Xcode re-baixa pacotes Swift/Carthage. Logs são apenas registros — não afeta builds nem simuladores.

---

## Passo 7 — node_modules dos projetos

**Pergunta:** "Apagar pastas node_modules dentro dos projetos em ~/dev?"

O que apaga:
- Todas as pastas `node_modules/` encontradas em `~/dev`, `~/projects`, `~/workspace`, `~/code`, `~/Documents`, `~/Desktop`

**Impacto:** precisa rodar `npm install` / `yarn install` / `pnpm install` em cada projeto antes de usar. Nada permanente, mas pode ser demorado se houver muitos projetos.

---

## Passo 8 — Apps desinstalados e caches de IDEs

**Pergunta:** "Limpar configurações de apps desinstalados e cache do VS Code?"

O que apaga:
- `~/Library/Application Support/<app>` de apps que não existem mais em `/Applications`
- `~/Library/Application Support/Code/Cache` — cache do VS Code
- `~/.nvm/.cache` — downloads em cache do nvm (não remove as versões Node instaladas)

**Impacto:** baixo. Configurações de apps que já não existem mais. VS Code recria o cache automaticamente.

---

## Passo 9 — Docker

**Pergunta:** "Limpar dados do Docker (VMs e volumes não usados)?"

O que apaga:
- `~/Library/Containers/com.docker.docker/Data/vms` — VMs do Docker Desktop
- Docker volumes orphaned (containers que não existem mais)

**Impacto:** médio. Volumes podem ter dados de containers parados que você ainda queira. Confirmar antes.

---

## Passo 10 — Homebrew

**Pergunta:** "Rodar limpeza do Homebrew (remover versões antigas de fórmulas)?"

O que apaga:
- `~/Library/Caches/Homebrew` — downloads antigos
- Versões antigas de fórmulas instaladas (via `brew cleanup`)

**Impacto:** baixo. Versões mais antigas de pacotes são removidas. Se precisar de uma versão antiga, precisará instalar novamente.

---

---

## Passo IMPORTANTE A — Emuladores Android (AVDs)

> Manter separado e destacado. Executar apenas para "começar do zero".

**Pergunta com atenção:** "Apagar TODOS os emuladores Android (AVDs)?"

O que apaga:
- `~/.android/avd` — todos os emuladores Android criados

**Impacto ALTO:**
- Todos os emuladores são removidos permanentemente
- Dados e apps instalados nos emuladores são perdidos
- Será necessário recriar os AVDs no Android Studio (Device Manager)
- Builds e runs continuam funcionando — só precisa de um novo emulador

**Requer:** digitar `yes` para confirmar (não aceita só `y`)

---

## Passo IMPORTANTE B — Simuladores iOS

> Manter separado e destacado. Executar apenas para "começar do zero".

**Pergunta com atenção:** "Apagar TODOS os simuladores iOS instalados?"

O que apaga:
- `~/Library/Developer/CoreSimulator/Devices` — todos os simuladores iOS

**Impacto ALTO:**
- Todos os simuladores são removidos permanentemente
- Apps instalados nos simuladores são perdidos
- O Xcode recria os simuladores padrão automaticamente ao ser aberto
- Simuladores customizados precisarão ser recriados manualmente em Window > Devices and Simulators

**Requer:** digitar `yes` para confirmar (não aceita só `y`)

---

## Passo IMPORTANTE C — Android SDK Platforms

> Manter separado e destacado. Risco de quebrar projetos.

**Pergunta com atenção:** "Apagar todas as versões do Android SDK instaladas?"

O que apaga:
- `~/Library/Android/sdk/platforms/android-*` — todas as versões do SDK (ex: android-33, android-34)

**Impacto ALTO:**
- Projetos que exigem uma versão específica do SDK não compilarão até reinstalar
- Reinstalação via Android Studio > SDK Manager
- O Gradle vai reclamar de SDK não encontrado nos projetos

**Requer:** digitar `yes` para confirmar (não aceita só `y`)

---

## Ordem sugerida de implementação no script

```
Passos automáticos (sem risco):       1, 2, 3
Passos com pequeno impacto:           4, 5, 6, 8, 10
Passos com impacto médio:             7, 9
Passos com ALTO impacto (separados):  A, B, C
```
