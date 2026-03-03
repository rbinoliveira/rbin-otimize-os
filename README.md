# rbin-otimize-os

<div align="center">

[🇧🇷 Português](#português) | [🇺🇸 English](#english)

</div>

---

<a name="português"></a>

## 🇧🇷 Português

Kit de otimização de sistema para macOS e Linux — memória, CPU e disco — com interface visual interativa.

### Instalação via npm (recomendado)

```bash
npm install -g rbin-otimize-os
```

Depois é só rodar:

```bash
rbin-otimize-os
```

### Instalação via git

```bash
git clone https://github.com/rbinoliveira/rbin-otimize-os.git
cd rbin-otimize-os
bash run.sh
```

### O que faz

Ao rodar, abre um menu visual com 3 opções:

```
╔══════════════════════════════════════════════════════════╗
║  rbin-otimize-os                                         ║
║  macOS 15.2                                              ║
╠══════════════════════════════════════════════════════════╣
║  RAM livre: 4.2 GB   Disco livre: 38G   CPU: 12%         ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  [1]  Melhorar Performance                               ║
║       Limpa memoria RAM e otimiza CPU                    ║
║                                                          ║
║  [2]  Analisar Uso de Disco                              ║
║       Visualiza categorias e arquivos grandes            ║
║                                                          ║
║  [3]  Otimizar Espaco em Disco                           ║
║       Remove caches, logs e arquivos desnecessarios      ║
║                                                          ║
║  [0]  Sair                                               ║
╚══════════════════════════════════════════════════════════╝
```

**[1] Melhorar Performance** — limpa memória RAM inativa e gerencia processos com alto uso de CPU.

**[2] Analisar Uso de Disco** — relatório visual por categoria (caches, logs, node_modules, Docker, etc.) com tamanhos.

**[3] Otimizar Espaço em Disco** — wizard passo a passo que pergunta o que você quer limpar antes de apagar qualquer coisa.

### Wizard de limpeza de disco

A opção [3] guia por passos agrupados por contexto:

| Passo | O que limpa |
|-------|-------------|
| 1 | Caches gerais, logs, /tmp, Lixeira |
| 2 | Caches JS/TS — npm, yarn, pnpm, bun, expo, turbo, Metro |
| 3 | Build outputs — dist/, build/, .next/, app/build Android, ios/build |
| 4 | Caches de teste — Jest, Playwright, Cypress |
| 5 | Caches Python, Ruby, .NET — pip, gem, bundler, NuGet |
| 6 | Caches iOS/Swift — SwiftPM, Carthage, logs Xcode *(macOS)* |
| 7 | node_modules dentro dos projetos em ~/dev |
| 8 | Configs de apps desinstalados, cache VS Code |
| 9 | Docker volumes não usados |
| 10 | Homebrew *(macOS)* / Gerenciadores de pacotes *(Linux)* |
| **A** | **Emuladores Android (AVDs)** — pede `yes` para confirmar |
| **B** | **Simuladores iOS** — pede `yes` para confirmar *(macOS)* |
| **C** | **Android SDK Platforms** — pede `yes` para confirmar |

Os passos A, B e C têm aviso destacado em vermelho e exigem digitar `yes` explicitamente — nunca são executados por acidente.

**Ambientes Android e iOS não são tocados** nos passos normais (1–10). DerivedData, Gradle cache, AVDs, SDK e simuladores só são removidos se você pedir explicitamente nos passos de alto risco.

### Flags disponíveis

```bash
rbin-otimize-os              # menu interativo
rbin-otimize-os --dry-run    # simula sem apagar nada
rbin-otimize-os --help       # ajuda
```

Para os scripts individuais:

```bash
rbin-otimize-os              # abre o menu principal
```

Ou direto pelos scripts (se instalado via git):

```bash
bash run.sh --dry-run
```

### Requisitos

- **macOS** 10.13+ ou **Linux** (Ubuntu 20.04+, Fedora 36+, Debian 11+, Arch)
- **Bash** 4.0+
- **Node.js** 14+ (apenas para instalar via npm — o script em si é bash puro)

### Licença

MIT

---

<a name="english"></a>

## 🇺🇸 English

System optimization toolkit for macOS and Linux — memory, CPU and disk — with a visual interactive interface.

### Install via npm (recommended)

```bash
npm install -g rbin-otimize-os
```

Then just run:

```bash
rbin-otimize-os
```

### Install via git

```bash
git clone https://github.com/rbinoliveira/rbin-otimize-os.git
cd rbin-otimize-os
bash run.sh
```

### What it does

Opens a visual menu with 3 options:

```
╔══════════════════════════════════════════════════════════╗
║  rbin-otimize-os                                         ║
║  macOS 15.2                                              ║
╠══════════════════════════════════════════════════════════╣
║  Free RAM: 4.2 GB   Free Disk: 38G   CPU: 12%            ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  [1]  Improve Performance                                ║
║       Clean inactive RAM and optimize CPU                ║
║                                                          ║
║  [2]  Analyze Disk Usage                                 ║
║       Visualize categories and large files               ║
║                                                          ║
║  [3]  Optimize Disk Space                                ║
║       Remove caches, logs and unnecessary files          ║
║                                                          ║
║  [0]  Exit                                               ║
╚══════════════════════════════════════════════════════════╝
```

**[1] Improve Performance** — clears inactive RAM and manages high-CPU processes.

**[2] Analyze Disk Usage** — visual report by category (caches, logs, node_modules, Docker, etc.) with sizes.

**[3] Optimize Disk Space** — step-by-step wizard that asks what you want to clean before deleting anything.

### Disk cleanup wizard

Option [3] guides through steps grouped by context:

| Step | What it cleans |
|------|---------------|
| 1 | General caches, logs, /tmp, Trash |
| 2 | JS/TS caches — npm, yarn, pnpm, bun, expo, turbo, Metro |
| 3 | Build outputs — dist/, build/, .next/, Android app/build, iOS ios/build |
| 4 | Test caches — Jest, Playwright, Cypress |
| 5 | Python, Ruby, .NET caches — pip, gem, bundler, NuGet |
| 6 | iOS/Swift caches — SwiftPM, Carthage, Xcode logs *(macOS)* |
| 7 | node_modules inside projects in ~/dev |
| 8 | Orphaned app configs, VS Code cache |
| 9 | Unused Docker volumes |
| 10 | Homebrew *(macOS)* / Package managers *(Linux)* |
| **A** | **Android Emulators (AVDs)** — requires typing `yes` |
| **B** | **iOS Simulators** — requires typing `yes` *(macOS)* |
| **C** | **Android SDK Platforms** — requires typing `yes` |

Steps A, B and C show a red highlighted warning and require explicitly typing `yes` — they can never be run by accident.

**Android and iOS dev environments are never touched** in normal steps (1–10). DerivedData, Gradle cache, AVDs, SDK and simulators are only removed if you explicitly request it in the high-risk steps.

### Available flags

```bash
rbin-otimize-os              # interactive menu
rbin-otimize-os --dry-run    # simulate without deleting anything
rbin-otimize-os --help       # help
```

### Requirements

- **macOS** 10.13+ or **Linux** (Ubuntu 20.04+, Fedora 36+, Debian 11+, Arch)
- **Bash** 4.0+
- **Node.js** 14+ (only needed to install via npm — the script itself is pure bash)

### License

MIT
