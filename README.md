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

A instalação roda automaticamente `rbin-otimize-os init` (configura pastas e permissões). Depois é só rodar:

```bash
rbin-otimize-os
```

Se precisar rodar o setup de novo manualmente:

```bash
rbin-otimize-os init
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

A opção [3] guia primeiro pelos passos normais e depois pelos passos em **vermelho**.

**Regra:** só é vermelho o que atrasa o build local de React Native (emulador/simulador).
Dando `y` em todos os passos normais, o próximo `run-android`/`run-ios` continua rápido.

| Passo | O que limpa |
|-------|-------------|
| 1–22 *(macOS)* / 1–9 *(Linux)* | Caches gerais, npm/yarn/pnpm/bun, build outputs web, testes, Python/Ruby/.NET, Xcode DeviceSupport, Docker, Homebrew, Gradle antigo, temporários, extras de IDE, caches de apps, Archives, runtimes antigos, Xcodes antigos, Time Machine, sistema, Downloads |
| **A** | **Caches do React Native** — Metro, CocoaPods, `~/.rncache`, `~/.expo` |
| **B** | **Xcode DerivedData** *(macOS)* |
| **C** | **Builds nativos** — `android/app/build`, `ios/build` |
| **D** | **node_modules** dos projetos |
| **E** | **Dependências de projetos parados** — Pods, .gradle, .cxx… *(macOS)* |
| **F** | **Snapshots de boot dos AVDs** *(macOS)* |
| **G** | **Cache de boot dos simuladores iOS** *(macOS)* |
| **H–L** | **AVDs, simuladores iOS, SDK Platforms, runtimes iOS, componentes do SDK Android** |

Os passos vermelhos sempre pedem confirmação, mesmo com `--force`. No Linux as letras são A (caches RN), B (builds), C (node_modules), D (AVDs), E (SDK Platforms).

### Comandos e flags

```bash
rbin-otimize-os              # menu interativo
rbin-otimize-os init         # configura o projeto (roda automaticamente apos npm install)
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

Installation automatically runs `rbin-otimize-os init` (sets up directories and permissions). Then just run:

```bash
rbin-otimize-os
```

To run setup again manually:

```bash
rbin-otimize-os init
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

### Commands and flags

```bash
rbin-otimize-os              # interactive menu
rbin-otimize-os init         # set up project (runs automatically after npm install)
rbin-otimize-os --dry-run    # simulate without deleting anything
rbin-otimize-os --help       # help
```

### Requirements

- **macOS** 10.13+ or **Linux** (Ubuntu 20.04+, Fedora 36+, Debian 11+, Arch)
- **Bash** 4.0+
- **Node.js** 14+ (only needed to install via npm — the script itself is pure bash)

### License

MIT
