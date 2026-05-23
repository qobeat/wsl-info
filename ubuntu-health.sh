#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=wsl2-info-lib.sh
. "$SCRIPT_DIR/wsl2-info-lib.sh"

usage() {
  cat <<'HELP'
ubuntu-health.sh - Ubuntu performance and health collector

USAGE:
  ubuntu-health.sh [--brief|--full] [--ollama] [--timeout SECONDS] [--output-dir DIR]
  ubuntu-health.sh --help

MODES:
  --brief   Core OS, CPU, memory, disk, processes, packages, and recent events.
  --full    Brief + events since boot, full package list, full systemd unit list.

DEFAULTS:
  mode: brief
  timeout: 10 seconds in brief mode, 60 seconds in full mode

NOTES:
  WSL-specific and Windows-side checks live in wsl2-shell.sh and wsl2-powershell.sh.
  No sudo is used. apt-get check is run only with passwordless sudo.
HELP
}

MODE="brief"
DO_OLLAMA=0
OUT=""
TIMEOUT_VALUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief) MODE="brief"; shift ;;
    --full) MODE="full"; shift ;;
    --ollama) DO_OLLAMA=1; shift ;;
    --timeout) [[ $# -ge 2 ]] || wi_die "--timeout requires SECONDS"; TIMEOUT_VALUE="$2"; shift 2 ;;
    --timeout=*) TIMEOUT_VALUE="${1#*=}"; shift ;;
    --output-dir) [[ $# -ge 2 ]] || wi_die "--output-dir requires DIR"; OUT="$2"; shift 2 ;;
    --output-dir=*) OUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) wi_die "unknown option for ubuntu-health.sh: $1" ;;
  esac
done

wi_validate_mode "$MODE"
if [[ -z "$TIMEOUT_VALUE" ]]; then
  TIMEOUT_VALUE="$(wi_default_timeout "$MODE")"
fi
wi_validate_timeout "$TIMEOUT_VALUE"

PROFILE="$MODE"
[[ "$DO_OLLAMA" -eq 1 ]] && PROFILE="$PROFILE-ollama"
if [[ -z "$OUT" ]]; then
  OUT="$HOME/tmp/ubuntu-health-$PROFILE-$(date +%Y%m%d-%H%M%S)"
fi

wi_init_run "ubuntu-health.sh" "$OUT" "$MODE" "$TIMEOUT_VALUE"
trap wi_finish_run EXIT
trap 'wi_finish_run; exit 143' TERM
trap 'wi_finish_run; exit 130' INT

if [[ "$MODE" == "full" ]]; then
  wi_run_capture "01-ubuntu-release.txt" 'uname -a; echo; cat /etc/os-release 2>/dev/null; echo; cat /proc/version 2>/dev/null; echo; systemd-detect-virt 2>/dev/null || true; echo; uptime; echo; if command -v inxi >/dev/null; then timeout 8 inxi -Fazy 2>/dev/null || echo "inxi timed out or failed"; else echo "inxi not installed; built-in inventory used instead"; fi'
else
  wi_run_capture "01-ubuntu-release.txt" 'uname -a; echo; cat /etc/os-release 2>/dev/null; echo; cat /proc/version 2>/dev/null; echo; systemd-detect-virt 2>/dev/null || true; echo; uptime; echo; echo "inxi skipped in brief mode"'
fi
wi_run_capture "02-cpu-memory.txt" 'lscpu 2>/dev/null; echo; free -h; echo; grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree" /proc/meminfo 2>/dev/null'
if [[ "$MODE" == "full" ]]; then
  wi_run_capture "03-disk-filesystems.txt" 'df -hT; echo; lsblk -f 2>/dev/null || true; echo; mount | sort; echo; timeout 8 du -sh "$HOME" 2>/dev/null || echo "home directory size timed out or failed"'
else
  wi_run_capture "03-disk-filesystems.txt" 'df -hT; echo; lsblk -f 2>/dev/null || true; echo; mount | sort; echo; echo "home directory size skipped in brief mode"'
fi
wi_run_capture "04-processes-listeners.txt" "ps -eo pid,ppid,stat,etime,%cpu,%mem,comm,args --sort=-%cpu | awk 'NR==1 || (\$7!=\"ps\" && \$0 !~ /(collect-status|wsl2-info|ubuntu-health)\\.sh/)' | head -80; echo; ss -tulpen 2>&1 | head -400"

if wi_have lsof; then
  wi_run_capture "05-lsof.txt" 'timeout 2 lsof -nP -i 2>&1 | head -800; echo; timeout 2 lsof -nP -iTCP -sTCP:LISTEN 2>&1'
else
  wi_write_notice "05-lsof.txt" "lsof not installed; optional: sudo apt install lsof"
fi

wi_run_capture "06-performance-gpu.txt" 'vmstat 1 2; echo; command -v iostat >/dev/null && timeout 3 iostat -xz 1 2 || echo "iostat not available or timed out"; echo; wi_nvidia_smi'
wi_run_capture "08-services-events.txt" 'systemctl --failed --no-pager 2>/dev/null || true; echo; journalctl -p 3 --since "5 minutes ago" --no-pager -o short-iso 2>/dev/null | tail -300; echo; journalctl -k --since "5 minutes ago" --no-pager -o short-iso 2>/dev/null | tail -300'
if [[ "$MODE" == "full" ]]; then
  wi_run_capture "07-package-health.txt" 'dpkg --audit; echo; if sudo -n true 2>/dev/null; then timeout 8 sudo -n apt-get check; else echo "apt-get check skipped: no passwordless sudo"; fi; echo; echo "dpkg -V sample:"; timeout 10 dpkg -V 2>&1 | head -300 || true; if command -v debsums >/dev/null; then echo; echo "debsums sample:"; timeout 10 debsums -s 2>&1 | head -300; fi'
else
  wi_run_capture "07-package-health.txt" 'dpkg --audit; echo; if sudo -n true 2>/dev/null; then timeout 3 sudo -n apt-get check; else echo "apt-get check skipped: no passwordless sudo"; fi; echo; echo "dpkg -V/debsums skipped in brief mode"'
fi

if [[ "$MODE" == "full" ]]; then
  wi_run_capture "09-events-since-boot.txt" 'journalctl -b --no-pager -o short-iso 2>/dev/null; echo; journalctl -p 3 -xb --no-pager -o short-iso 2>/dev/null; echo; journalctl -k -b --no-pager -o short-iso 2>/dev/null'
  wi_run_capture "10-package-list-full.txt" 'echo "=== manual packages ==="; apt-mark showmanual | sort; echo; echo "=== installed packages ==="; dpkg-query -W -f="${Package}\t${Version}\t${Architecture}\n" | sort'
  wi_run_capture "11-systemd-units-full.txt" 'systemctl list-units --all --no-pager 2>/dev/null || true'
fi

if [[ "$DO_OLLAMA" -eq 1 ]]; then
  wi_run_capture "20-ollama-health.txt" 'echo "=== Ollama binary/process ==="; command -v ollama || true; if command -v ollama >/dev/null; then ollama --version 2>&1 || true; else echo "ollama not installed"; fi; pgrep -a ollama || true; echo; echo "=== Listen/API ==="; ss -ltnp 2>/dev/null | grep -E "(:11434|ollama)" || true; wi_http_get http://127.0.0.1:11434/api/version || true; echo; echo "=== Local models ==="; if command -v ollama >/dev/null; then ollama list 2>&1 || true; else echo "ollama not installed"; fi; wi_http_get http://127.0.0.1:11434/api/tags || true; echo; echo "=== Running models ==="; if command -v ollama >/dev/null; then ollama ps 2>&1 || true; else echo "ollama not installed"; fi; wi_http_get http://127.0.0.1:11434/api/ps || true; echo; echo "=== Model disk ==="; du -sh ~/.ollama ~/.ollama/models ~/.ollama/models/blobs 2>/dev/null || true; du -h ~/.ollama/models/blobs/* 2>/dev/null | sort -h | tail -25 || true; echo; echo "=== GPU ==="; wi_nvidia_smi'
fi
