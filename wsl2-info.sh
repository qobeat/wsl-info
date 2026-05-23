#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=wsl2-info-lib.sh
. "$SCRIPT_DIR/wsl2-info-lib.sh"

usage() {
  cat <<'HELP'
wsl2-info.sh - WSL2 health collector glue script

USAGE:
  wsl2-info.sh --brief [--network] [--ollama] [--timeout SECONDS] [--output-dir DIR]
  wsl2-info.sh --full  [--network] [--ollama] [--timeout SECONDS] [--output-dir DIR]
  wsl2-info.sh --network [--timeout SECONDS]
  wsl2-info.sh --ollama  [--timeout SECONDS]
  wsl2-info.sh --help

DEFAULT:
  No arguments: show this help only.

MODES:
  --brief   Core summary from Ubuntu health, WSL Linux-side, and Windows-side WSL checks.
  --full    Brief + expanded event/package/systemd/WSL details.
  --network Add Linux-side and Windows-side WSL network checks.
  --ollama  Add Ollama process/API/model/GPU checks in the Ubuntu health collector.

TIMEOUT:
  Each child collector gets its own runtime budget.
  Defaults: 10 seconds in brief mode, 60 seconds in full mode.

OUTPUT:
  ~/tmp/wsl2-info-<options>-<yyyy-mm-dd>.zip when zip is installed.
HELP
}

[[ $# -eq 0 ]] && usage && exit 0

MODE=""
DO_NET=0
DO_OLLAMA=0
OUT=""
TIMEOUT_VALUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief) MODE="brief"; shift ;;
    --full) MODE="full"; shift ;;
    --network) DO_NET=1; shift ;;
    --ollama) DO_OLLAMA=1; shift ;;
    --timeout) [[ $# -ge 2 ]] || wi_die "--timeout requires SECONDS"; TIMEOUT_VALUE="$2"; shift 2 ;;
    --timeout=*) TIMEOUT_VALUE="${1#*=}"; shift ;;
    --output-dir) [[ $# -ge 2 ]] || wi_die "--output-dir requires DIR"; OUT="$2"; shift 2 ;;
    --output-dir=*) OUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) wi_die "unknown option for wsl2-info.sh: $1" ;;
  esac
done

if [[ -z "$MODE" ]]; then
  MODE="brief"
fi
wi_validate_mode "$MODE"
if [[ -z "$TIMEOUT_VALUE" ]]; then
  TIMEOUT_VALUE="$(wi_default_timeout "$MODE")"
fi
wi_validate_timeout "$TIMEOUT_VALUE"

DATE="$(date +%F)"
STAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="$HOME/tmp"
PROFILE="$MODE"
[[ "$DO_NET" -eq 1 ]] && PROFILE="$PROFILE-network"
[[ "$DO_OLLAMA" -eq 1 ]] && PROFILE="$PROFILE-ollama"
if [[ -z "$OUT" ]]; then
  OUT="$ROOT/wsl2-info-$PROFILE-$STAMP"
fi
ZIPFILE="$ROOT/wsl2-info-$PROFILE-$DATE.zip"
mkdir -p "$ROOT" "$OUT"

GLUE_START_EPOCH="$(date +%s)"
GLUE_START_ISO="$(date -Is)"
{
  echo "script: wsl2-info.sh"
  echo "mode: $MODE"
  echo "timeout_seconds_per_child: $TIMEOUT_VALUE"
  echo "start_time: $GLUE_START_ISO"
  echo "output_dir: $OUT"
} >"$OUT/00-run-metadata.txt"

finish_glue_run() {
  [[ "${GLUE_FINISHED:-0}" -eq 1 ]] && return 0
  GLUE_FINISHED=1

  local end_epoch
  end_epoch="$(date +%s)"
  {
    echo "end_time: $(date -Is)"
    echo "duration_seconds: $((end_epoch - GLUE_START_EPOCH))"
  } >>"$OUT/00-run-metadata.txt"
}

trap finish_glue_run EXIT
trap 'finish_glue_run; exit 143' TERM
trap 'finish_glue_run; exit 130' INT

run_child() {
  local label="$1"
  local script="$2"
  local child_out="$3"
  shift 3

  echo "Running $label..."
  local start_epoch end_epoch rc
  start_epoch="$(date +%s)"
  "$script" --"$MODE" --timeout "$TIMEOUT_VALUE" --output-dir "$child_out" "$@"
  rc=$?
  end_epoch="$(date +%s)"
  {
    echo "child: $label"
    echo "script: $script"
    echo "output_dir: $child_out"
    echo "exit: $rc"
    echo "duration_seconds: $((end_epoch - start_epoch))"
    echo
  } >>"$OUT/child-runs.txt"
  return 0
}

UBUNTU_OUT="$OUT/ubuntu-health"
WSL_SHELL_OUT="$OUT/wsl2-shell"
WSL_PS_OUT="$OUT/wsl2-powershell"

ubuntu_args=()
[[ "$DO_OLLAMA" -eq 1 ]] && ubuntu_args+=(--ollama)

wsl_args=()
[[ "$DO_NET" -eq 1 ]] && wsl_args+=(--network)

run_child "Ubuntu health" "$SCRIPT_DIR/ubuntu-health.sh" "$UBUNTU_OUT" "${ubuntu_args[@]}"
run_child "WSL2 Linux-side" "$SCRIPT_DIR/wsl2-shell.sh" "$WSL_SHELL_OUT" "${wsl_args[@]}"
run_child "WSL2 PowerShell" "$SCRIPT_DIR/wsl2-powershell.sh" "$WSL_PS_OUT" "${wsl_args[@]}"

metadata_line() {
  local dir="$1"
  local meta="$dir/00-run-metadata.txt"
  if [[ -f "$meta" ]]; then
    awk -F': ' '
      /^script:/ { script=$2 }
      /^duration_seconds:/ { duration=$2 }
      /^timed_out:/ { timed_out=$2 }
      END {
        if (script != "") {
          suffix = timed_out == "yes" ? " (timeout reached)" : ""
          printf "%s: %ss%s\n", script, duration == "" ? "?" : duration, suffix
        }
      }
    ' "$meta"
  else
    printf "%s: no metadata\n" "$(basename "$dir")"
  fi
}

package_summary() {
  local file="$UBUNTU_OUT/07-package-health.txt"
  local pkg="No obvious dpkg audit issue"
  if [[ -f "$file" ]]; then
    grep -qi 'apt-get check skipped' "$file" && pkg="Limited: dpkg audit only; apt-get check needs sudo"
    grep -Eiq 'dependency problems|not fully installed|unconfigured|permission denied|unable to acquire|^E:' "$file" && pkg="Package check needs review: see ubuntu-health/07-package-health.txt"
  else
    pkg="Package check unavailable: ubuntu-health/07-package-health.txt missing"
  fi
  echo "$pkg"
}

DISTRO="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null)"
MEM="$(free -h | awk '/^Mem:/{print $3 " used / " $2 " total; " $7 " available"}')"
DISK="$(df -h / | awk 'NR==2{print $5 " used; " $4 " free on /"}')"
FAILS="$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)"
ERR5="$(journalctl -p 3 --since "5 minutes ago" --no-pager 2>/dev/null | grep -c . || true)"

NETSUM=""
if [[ "$DO_NET" -eq 1 ]]; then
  if timeout 3 ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
    NETSUM="network-ip: OK"
  else
    NETSUM="network-ip: CHECK"
  fi
fi

OLLSUM=""
if [[ "$DO_OLLAMA" -eq 1 ]]; then
  if wi_http_get http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    OLLSUM="ollama-api: OK"
  else
    OLLSUM="ollama-api: CHECK"
  fi
fi

PSSUM="powershell: available"
if ! wi_have powershell.exe && ! wi_have pwsh.exe && ! wi_have pwsh; then
  PSSUM="powershell: CHECK - executable not found"
fi

{
  echo "=== WSL2 INFO SUMMARY ==="
  echo "profile: $PROFILE"
  echo "time: $(date -Is)"
  echo "mode timeout per collector: ${TIMEOUT_VALUE}s"
  echo "distro: ${DISTRO:-unknown}"
  echo "kernel: $(uname -r)"
  echo "uptime: $(uptime -p 2>/dev/null || uptime)"
  echo "memory: $MEM"
  echo "disk: $DISK"
  echo "failed systemd units: $FAILS"
  echo "last-5-min critical/error events: $ERR5"
  echo "$PSSUM"
  [[ -n "$NETSUM" ]] && echo "$NETSUM"
  [[ -n "$OLLSUM" ]] && echo "$OLLSUM"
  echo
  echo "Collector runtimes:"
  metadata_line "$UBUNTU_OUT"
  metadata_line "$WSL_SHELL_OUT"
  metadata_line "$WSL_PS_OUT"
  echo
  echo "Top CPU processes:"
  ps -eo pid,%cpu,%mem,comm,args --sort=-%cpu | awk 'NR==1 || ($4!="ps" && $4!="awk" && $4!="head" && $4!="tee" && $0 !~ /(collect-status|wsl2-info)\.sh/)' | head -8
  echo
  echo "Package health:"
  package_summary
} | tee "$OUT/summary.txt"

if wi_have zip; then
  rm -f "$ZIPFILE"
  (cd "$OUT" && zip -qr "$ZIPFILE" .)
  SIZE="$(du -h "$ZIPFILE" | awk '{print $1}')"
  echo
  echo "ZIP: $ZIPFILE"
  echo "SIZE: $SIZE"
else
  echo
  echo "ZIP: not created; zip command is not installed"
fi

echo "Collected directory: $OUT"
