# scripts
## wsl2-info.sh

Install:

```bash
mkdir -p ~/.local/bin
cp wsl2-info-lib.sh ubuntu-health.sh wsl2-shell.sh wsl2-powershell.sh wsl2-info.sh collect-status.sh ~/.local/bin/
chmod +x ~/.local/bin/ubuntu-health.sh ~/.local/bin/wsl2-shell.sh ~/.local/bin/wsl2-powershell.sh ~/.local/bin/wsl2-info.sh ~/.local/bin/collect-status.sh
```

Examples:

```bash
wsl2-info.sh --brief
wsl2-info.sh --full
wsl2-info.sh --brief --network --ollama
wsl2-info.sh --ollama
wsl2-info.sh --brief --timeout 20
```

`collect-status.sh` remains as a compatibility wrapper around `wsl2-info.sh`.

Split collectors:

- `ubuntu-health.sh`: WSL2-agnostic Ubuntu performance, package, service, event, GPU, and optional Ollama checks.
- `wsl2-shell.sh`: WSL2 Linux-side checks and optional Linux-side network diagnostics.
- `wsl2-powershell.sh`: Windows-side WSL2 checks through PowerShell and optional Windows-side network diagnostics.
- `wsl2-info-lib.sh`: shared utility functions.

Each collector captures its own start/end time in `00-run-metadata.txt`. The per-collector runtime budget defaults to 10 seconds in brief mode and 60 seconds in full mode; override it with `--timeout SECONDS`.
