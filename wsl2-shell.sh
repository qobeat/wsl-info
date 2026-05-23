#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=wsl2-info-lib.sh
. "$SCRIPT_DIR/wsl2-info-lib.sh"

usage() {
  cat <<'HELP'
wsl2-shell.sh - Linux-side WSL2 collector

USAGE:
  wsl2-shell.sh [--brief|--full] [--network] [--timeout SECONDS] [--output-dir DIR]
  wsl2-shell.sh --help

MODES:
  --brief   WSL Linux environment, WSL config, interop, and WSL mounts.
  --full    Brief + expanded WSL environment details.

DEFAULTS:
  mode: brief
  timeout: 10 seconds in brief mode, 60 seconds in full mode
HELP
}

MODE="brief"
DO_NET=0
OUT=""
TIMEOUT_VALUE=""
MS_NET="https://raw.githubusercontent.com/microsoft/WSL/master/diagnostics/networking.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief) MODE="brief"; shift ;;
    --full) MODE="full"; shift ;;
    --network) DO_NET=1; shift ;;
    --timeout) [[ $# -ge 2 ]] || wi_die "--timeout requires SECONDS"; TIMEOUT_VALUE="$2"; shift 2 ;;
    --timeout=*) TIMEOUT_VALUE="${1#*=}"; shift ;;
    --output-dir) [[ $# -ge 2 ]] || wi_die "--output-dir requires DIR"; OUT="$2"; shift 2 ;;
    --output-dir=*) OUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) wi_die "unknown option for wsl2-shell.sh: $1" ;;
  esac
done

wi_validate_mode "$MODE"
if [[ -z "$TIMEOUT_VALUE" ]]; then
  TIMEOUT_VALUE="$(wi_default_timeout "$MODE")"
fi
wi_validate_timeout "$TIMEOUT_VALUE"

PROFILE="$MODE"
[[ "$DO_NET" -eq 1 ]] && PROFILE="$PROFILE-network"
if [[ -z "$OUT" ]]; then
  OUT="$HOME/tmp/wsl2-shell-$PROFILE-$(date +%Y%m%d-%H%M%S)"
fi

wi_init_run "wsl2-shell.sh" "$OUT" "$MODE" "$TIMEOUT_VALUE"
trap wi_finish_run EXIT
trap 'wi_finish_run; exit 143' TERM
trap 'wi_finish_run; exit 130' INT

wi_run_capture "01-wsl-linux-environment.txt" 'echo "=== Kernel/version ==="; uname -a; echo; cat /proc/version 2>/dev/null; echo; echo "=== Virtualization ==="; systemd-detect-virt 2>/dev/null || true; echo; echo "=== WSL env ==="; printf "WSL_DISTRO_NAME=%s\n" "${WSL_DISTRO_NAME:-}"; printf "WSL_INTEROP=%s\n" "${WSL_INTEROP:-}"; printf "WSLENV=%s\n" "${WSLENV:-}"; echo; echo "=== WSL config ==="; [ -f /etc/wsl.conf ] && cat /etc/wsl.conf || echo "/etc/wsl.conf not found"; echo; echo "=== Interop ==="; ls -l /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null || true'
wi_run_capture "02-wsl-mounts.txt" 'echo "=== WSL related mounts ==="; mount | sort | grep -Ei "drvfs|wsl|9p|plan9|lxfs" || true; echo; echo "=== /mnt ==="; ls -la /mnt 2>/dev/null || true; echo; echo "=== /etc/fstab ==="; [ -f /etc/fstab ] && cat /etc/fstab || true'

if [[ "$MODE" == "full" ]]; then
  wi_run_capture "03-wsl-environment-full.txt" 'echo "=== Selected environment ==="; env | sort | grep -E "^(DISPLAY|PULSE_SERVER|WAYLAND_DISPLAY|WSL|WSLENV|WT_|TERM|PATH)=" || true; echo; echo "=== WSL runtime paths ==="; find /run -maxdepth 2 \( -iname "*wsl*" -o -iname "*WSL*" \) -print 2>/dev/null | sort; echo; echo "=== binfmt WSLInterop ==="; cat /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null || true'
fi

if [[ "$DO_NET" -eq 1 ]]; then
  wi_run_capture "20-network-linux.txt" 'echo "=== Linux network ==="; ip -brief addr 2>/dev/null || true; echo; ip route 2>/dev/null || true; echo; ip neigh show 2>/dev/null || true; echo; echo "=== DNS/resolver ==="; cat /etc/resolv.conf 2>/dev/null || true; echo; [ -f /etc/wsl.conf ] && cat /etc/wsl.conf || true; echo; echo "=== DNS lookup ==="; getent hosts github.com microsoft.com ubuntu.com || true; echo; echo "=== ping ==="; ping -c 2 -W 2 1.1.1.1 || true; ping -c 2 -W 2 github.com || true'
  wi_download_capture "21-download-networking-helper.txt" "$MS_NET" "$WI_OUT/networking.sh"
  wi_write_notice "README-OFFICIAL-WSL-NETWORK-HELPER.txt" "Official Microsoft Linux-side WSL networking helper downloaded when available:" "$MS_NET" "" "It is saved as networking.sh in this directory. Review it before running."
fi
