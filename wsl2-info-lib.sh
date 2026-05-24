#!/usr/bin/env bash
# Shared helpers for the wsl2-info collector scripts.

wi_have() {
  command -v "$1" >/dev/null 2>&1
}

wi_die() {
  echo "ERROR: $*" >&2
  exit 2
}

wi_now_ms() {
  date +%s%3N
}

wi_human_time() {
  date '+%F %T'
}

wi_elapsed_seconds() {
  local start_ms="$1"
  local end_ms="${2:-$(wi_now_ms)}"
  awk -v start="$start_ms" -v end="$end_ms" 'BEGIN { printf "%.1f", (end - start) / 1000 }'
}

wi_default_timeout() {
  case "${1:-brief}" in
    full) echo 60 ;;
    brief) echo 10 ;;
    *) wi_die "unknown mode: $1" ;;
  esac
}

wi_validate_mode() {
  case "$1" in
    brief|full) return 0 ;;
    *) wi_die "mode must be brief or full: $1" ;;
  esac
}

wi_validate_timeout() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || wi_die "timeout must be a non-negative integer: ${1:-}"
}

wi_init_run() {
  WI_SCRIPT_NAME="$1"
  WI_OUT="$2"
  WI_MODE="$3"
  WI_TIMEOUT="$4"
  WI_START_EPOCH="$(date +%s)"
  WI_START_MS="$(wi_now_ms)"
  WI_START_ISO="$(date -Is)"
  WI_TIMED_OUT=0
  WI_FINISHED=0

  mkdir -p "$WI_OUT"
  {
    echo "script: $WI_SCRIPT_NAME"
    echo "mode: $WI_MODE"
    echo "timeout_seconds: $WI_TIMEOUT"
    echo "start_time: $WI_START_ISO"
    echo "output_dir: $WI_OUT"
  } >"$WI_OUT/00-run-metadata.txt"
}

wi_finish_run() {
  [[ "${WI_FINISHED:-0}" -eq 1 ]] && return 0
  WI_FINISHED=1

  local end_iso duration timeout_state
  end_iso="$(date -Is)"
  duration="$(wi_elapsed_seconds "$WI_START_MS")"

  timeout_state="no"
  [[ "${WI_TIMED_OUT:-0}" -eq 1 ]] && timeout_state="yes"

  {
    echo "end_time: $end_iso"
    echo "duration_seconds: $duration"
    echo "timed_out: $timeout_state"
  } >>"$WI_OUT/00-run-metadata.txt"
}

wi_remaining_seconds() {
  if [[ "${WI_TIMEOUT:-0}" -eq 0 ]]; then
    echo 0
    return 0
  fi

  local now deadline remaining
  now="$(date +%s)"
  deadline=$((WI_START_EPOCH + WI_TIMEOUT))
  remaining=$((deadline - now))
  if (( remaining < 0 )); then
    remaining=0
  fi
  echo "$remaining"
}

wi_run_capture() {
  local file="$1"
  shift
  local command="$*"
  local target="$WI_OUT/$file"
  local start_ms start_iso end_iso duration remaining rc

  start_ms="$(wi_now_ms)"
  start_iso="$(date -Is)"
  rc=0

  {
    echo "### collector: ${WI_SCRIPT_NAME:-unknown}"
    echo "### start: $start_iso"
    echo "### command: $command"

    if [[ "${WI_TIMEOUT:-0}" -gt 0 ]]; then
      remaining="$(wi_remaining_seconds)"
      echo "### remaining-runtime-timeout: ${remaining}s"
      echo

      if (( remaining <= 0 )); then
        echo "### skipped: collector runtime timeout reached before command started"
        rc=124
      else
        timeout --kill-after=2s "${remaining}s" bash -lc "$command"
        rc=$?
      fi
    else
      echo "### remaining-runtime-timeout: unlimited"
      echo
      bash -lc "$command"
      rc=$?
    fi

    end_iso="$(date -Is)"
    duration="$(wi_elapsed_seconds "$start_ms")"
    echo
    echo "### end: $end_iso"
    echo "### duration_seconds: $duration"
    echo "### exit: $rc"
  } >"$target" 2>&1 || true

  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    WI_TIMED_OUT=1
  fi
}

wi_write_notice() {
  local file="$1"
  shift
  {
    echo "### collector: ${WI_SCRIPT_NAME:-unknown}"
    echo "### time: $(date -Is)"
    echo
    printf '%s\n' "$@"
  } >"$WI_OUT/$file" 2>&1 || true
}

wi_http_get() {
  local url="$1"
  if wi_have curl; then
    curl -fsS --max-time 5 "$url"
  elif wi_have python3; then
    python3 - "$url" <<'PY'
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=5) as response:
    print(response.read().decode("utf-8", "replace"))
PY
  else
    return 127
  fi
}

wi_download() {
  local url="$1"
  local out="$2"
  if wi_have curl; then
    curl -fsSL --max-time 12 -o "$out" "$url"
  elif wi_have python3; then
    python3 - "$url" "$out" <<'PY'
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  else
    return 127
  fi
}

wi_download_capture() {
  local file="$1"
  local url="$2"
  local out="$3"
  local target="$WI_OUT/$file"
  local start_ms start_iso end_iso duration remaining rc

  start_ms="$(wi_now_ms)"
  start_iso="$(date -Is)"
  rc=0

  {
    echo "### collector: ${WI_SCRIPT_NAME:-unknown}"
    echo "### start: $start_iso"
    echo "### download: $url"
    echo "### output: $out"

    if [[ "${WI_TIMEOUT:-0}" -gt 0 ]]; then
      remaining="$(wi_remaining_seconds)"
      echo "### remaining-runtime-timeout: ${remaining}s"
      echo

      if (( remaining <= 0 )); then
        echo "### skipped: collector runtime timeout reached before download started"
        rc=124
      else
        timeout --kill-after=2s "${remaining}s" bash -c 'wi_download "$1" "$2"' _ "$url" "$out"
        rc=$?
      fi
    else
      echo "### remaining-runtime-timeout: unlimited"
      echo
      wi_download "$url" "$out"
      rc=$?
    fi

    end_iso="$(date -Is)"
    duration="$(wi_elapsed_seconds "$start_ms")"
    echo
    echo "### end: $end_iso"
    echo "### duration_seconds: $duration"
    echo "### exit: $rc"
  } >"$target" 2>&1 || true

  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    WI_TIMED_OUT=1
  fi
}

wi_clean_windows_output() {
  tr -d '\000\r'
}

wi_powershell() {
  local command="$1"
  local ps=""

  if wi_have powershell.exe; then
    ps="powershell.exe"
  elif wi_have pwsh.exe; then
    ps="pwsh.exe"
  elif wi_have pwsh; then
    ps="pwsh"
  else
    echo "PowerShell executable not found on PATH"
    return 127
  fi

  if [[ "$ps" == *.exe ]]; then
    "$ps" -NoProfile -ExecutionPolicy Bypass -Command "$command" 2>&1 | wi_clean_windows_output
    return "${PIPESTATUS[0]}"
  fi

  "$ps" -NoProfile -Command "$command" 2>&1 | wi_clean_windows_output
  return "${PIPESTATUS[0]}"
}

wi_nvidia_smi() {
  if wi_have nvidia-smi; then
    nvidia-smi
  elif [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
    /usr/lib/wsl/lib/nvidia-smi
  else
    echo "nvidia-smi not found"
  fi
}

wi_script_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[1]}")" >/dev/null 2>&1 && pwd
}

export -f wi_have wi_http_get wi_download wi_clean_windows_output wi_powershell wi_nvidia_smi
