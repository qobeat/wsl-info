#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=wsl2-info-lib.sh
. "$SCRIPT_DIR/wsl2-info-lib.sh"

usage() {
  cat <<'HELP'
wsl2-info.sh - WSL2 health collector glue script

USAGE:
  wsl2-info.sh --brief [--network] [--ollama] [--error] [--timeout SECONDS] [--output-dir DIR]
  wsl2-info.sh --full  [--network] [--ollama] [--error] [--timeout SECONDS] [--output-dir DIR]
  wsl2-info.sh --network [--error] [--timeout SECONDS]
  wsl2-info.sh --ollama  [--error] [--timeout SECONDS]
  wsl2-info.sh --all [--timeout SECONDS]
  wsl2-info.sh --help

DEFAULT:
  No arguments: show this help only.

MODES:
  --brief   Core WSL2 + Ubuntu health summary.
  --full    Brief + expanded event/package/systemd/WSL details.
  --network Focus on WSL2 Linux-side and Windows-side network diagnostics.
  --ollama  Focus on Ollama GPU/runtime visibility.
  --error   Print grouped journal error classes at the end of the screen report.
  --all     Full collection plus network, Ollama, and grouped error output.

TIMEOUT:
  Each child collector gets its own runtime budget.
  Defaults: 10 seconds in brief mode, 60 seconds in full mode.

OUTPUT:
  ~/tmp/wsl2-info-<options>-<yyyy-mm-dd>.zip when zip is installed.
HELP
}

[[ $# -eq 0 ]] && usage && exit 0

MODE=""
MODE_SET=0
DO_NET=0
DO_OLLAMA=0
DO_ERROR=0
DO_ALL=0
OUT=""
TIMEOUT_VALUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief) MODE="brief"; MODE_SET=1; shift ;;
    --full) MODE="full"; MODE_SET=1; shift ;;
    --network) DO_NET=1; shift ;;
    --ollama) DO_OLLAMA=1; shift ;;
    --error|--errors) DO_ERROR=1; shift ;;
    --all) DO_ALL=1; MODE="full"; MODE_SET=1; DO_NET=1; DO_OLLAMA=1; DO_ERROR=1; shift ;;
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

FOCUS="summary"
if [[ "$DO_ALL" -eq 1 ]]; then
  FOCUS="all"
elif [[ "$MODE_SET" -eq 0 && "$DO_NET" -eq 1 && "$DO_OLLAMA" -eq 0 ]]; then
  FOCUS="network"
elif [[ "$MODE_SET" -eq 0 && "$DO_OLLAMA" -eq 1 && "$DO_NET" -eq 0 ]]; then
  FOCUS="ollama"
fi

DATE="$(date +%F)"
STAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="$HOME/tmp"
if [[ "$DO_ALL" -eq 1 ]]; then
  PROFILE="all"
else
  PROFILE="$MODE"
  [[ "$FOCUS" == "network" ]] && PROFILE="network"
  [[ "$FOCUS" == "ollama" ]] && PROFILE="ollama"
  [[ "$FOCUS" == "summary" && "$DO_NET" -eq 1 ]] && PROFILE="$PROFILE-network"
  [[ "$FOCUS" == "summary" && "$DO_OLLAMA" -eq 1 ]] && PROFILE="$PROFILE-ollama"
  [[ "$DO_ERROR" -eq 1 ]] && PROFILE="$PROFILE-error"
fi
if [[ -z "$OUT" ]]; then
  OUT="$ROOT/wsl2-info-$PROFILE-$STAMP"
fi
ZIPFILE="$ROOT/wsl2-info-$PROFILE-$DATE.zip"
mkdir -p "$ROOT" "$OUT"

GLUE_START_MS="$(wi_now_ms)"
GLUE_START_ISO="$(date -Is)"
{
  echo "script: wsl2-info.sh"
  echo "mode: $MODE"
  echo "profile: $PROFILE"
  echo "focus: $FOCUS"
  echo "timeout_seconds_per_child: $TIMEOUT_VALUE"
  echo "start_time: $GLUE_START_ISO"
  echo "output_dir: $OUT"
} >"$OUT/00-run-metadata.txt"

finish_glue_run() {
  [[ "${GLUE_FINISHED:-0}" -eq 1 ]] && return 0
  GLUE_FINISHED=1

  {
    echo "end_time: $(date -Is)"
    echo "duration_seconds: $(wi_elapsed_seconds "$GLUE_START_MS")"
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

  local start_ms rc elapsed status
  start_ms="$(wi_now_ms)"
  printf '[%s] Collecting: %s ... ' "$(wi_human_time)" "$label"
  "$script" --"$MODE" --timeout "$TIMEOUT_VALUE" --output-dir "$child_out" "$@"
  rc=$?
  elapsed="$(wi_elapsed_seconds "$start_ms")"
  status="done"
  [[ "$rc" -ne 0 ]] && status="failed (exit $rc)"
  printf '%s, elapsed %s s\n' "$status" "$elapsed"
  {
    echo "child: $label"
    echo "script: $script"
    echo "output_dir: $child_out"
    echo "exit: $rc"
    echo "duration_seconds: $elapsed"
    echo
  } >>"$OUT/child-runs.txt"
  return 0
}

UBUNTU_OUT="$OUT/ubuntu-health"
WSL_SHELL_OUT="$OUT/wsl2-shell"
WSL_PS_OUT="$OUT/wsl2-powershell"

RUN_UBUNTU=1
RUN_SHELL=1
RUN_PS=1
if [[ "$FOCUS" == "network" ]]; then
  RUN_UBUNTU=0
elif [[ "$FOCUS" == "ollama" ]]; then
  RUN_SHELL=0
  RUN_PS=0
fi

ubuntu_args=()
[[ "$DO_OLLAMA" -eq 1 ]] && ubuntu_args+=(--ollama)

wsl_args=()
[[ "$DO_NET" -eq 1 ]] && wsl_args+=(--network)

[[ "$RUN_UBUNTU" -eq 1 ]] && run_child "Ubuntu health" "$SCRIPT_DIR/ubuntu-health.sh" "$UBUNTU_OUT" "${ubuntu_args[@]}"
[[ "$RUN_SHELL" -eq 1 ]] && run_child "WSL2 Linux-side" "$SCRIPT_DIR/wsl2-shell.sh" "$WSL_SHELL_OUT" "${wsl_args[@]}"
[[ "$RUN_PS" -eq 1 ]] && run_child "WSL2 PowerShell" "$SCRIPT_DIR/wsl2-powershell.sh" "$WSL_PS_OUT" "${wsl_args[@]}"

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
          suffix = timed_out == "yes" ? " timeout" : " ok"
          printf "%-21s %6ss   %s\n", script, duration == "" ? "?" : duration, suffix
        }
      }
    ' "$meta"
  fi
}

ps_query() {
  local command="$1"
  if wi_have powershell.exe || wi_have pwsh.exe || wi_have pwsh; then
    timeout 8 bash -c 'wi_powershell "$1"' _ "$command" 2>/dev/null || true
  fi
}

host_hardware_kv() {
  ps_query '$cs=Get-CimInstance Win32_ComputerSystem; "host_cpu_logical=$($cs.NumberOfLogicalProcessors)"; "host_cpu_packages=$($cs.NumberOfProcessors)"; "host_memory_gib={0:N1}" -f ($cs.TotalPhysicalMemory/1GB)'
}

host_disks() {
  ps_query 'Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object { "{0}|{1:N1}|{2:N1}|{3:N1}" -f $_.DeviceID,($_.Size/1GB),(($_.Size-$_.FreeSpace)/1GB),($_.FreeSpace/1GB) }'
}

kv_lookup() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { print $2; found=1; exit } END { if (!found) exit 1 }'
}

human_bytes() {
  local bytes="$1"
  if wi_have numfmt; then
    local formatted
    formatted="$(numfmt --to=iec-i --suffix=B --format='%.1f' "$bytes" 2>/dev/null || true)"
    if [[ -n "$formatted" ]]; then
      printf '%s\n' "$formatted" | sed -E 's/([0-9])([KMGTPE]iB)$/\1 \2/'
    else
      echo "${bytes}B"
    fi
  else
    awk -v b="$bytes" 'BEGIN { printf "%.1f GiB", b / 1024 / 1024 / 1024 }'
  fi
}

section_title() {
  printf '\n## %s\n' "$1"
}

print_kv_table_header() {
  printf '%-14s %-24s %-34s %s\n' "CATEGORY" "ITEM" "VALUE" "NOTES"
  printf '%-14s %-24s %-34s %s\n' "--------" "----" "-----" "-----"
}

render_hardware_info() {
  local host_kv host_cpu host_pkgs host_mem
  local linux_cpu cpu_model mem_total mem_used mem_avail root_line
  host_kv="$(host_hardware_kv)"
  host_cpu="$(printf '%s\n' "$host_kv" | kv_lookup host_cpu_logical || true)"
  host_pkgs="$(printf '%s\n' "$host_kv" | kv_lookup host_cpu_packages || true)"
  host_mem="$(printf '%s\n' "$host_kv" | kv_lookup host_memory_gib || true)"
  linux_cpu="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo unknown)"
  cpu_model="$(awk -F: '/model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null)"
  mem_total="$(awk '/^Mem:/ { print $2 }' < <(free -b))"
  mem_used="$(awk '/^Mem:/ { print $3 }' < <(free -b))"
  mem_avail="$(awk '/^Mem:/ { print $7 }' < <(free -b))"

  section_title "HARDWARE INFO"
  print_kv_table_header
  printf '%-14s %-24s %-34s %s\n' "CPU" "WSL logical CPUs" "$linux_cpu" "${cpu_model:-visible to Linux}"
  [[ -n "$host_cpu" ]] && printf '%-14s %-24s %-34s %s\n' "CPU" "Host logical CPUs" "$host_cpu" "Windows host"
  [[ -n "$host_pkgs" ]] && printf '%-14s %-24s %-34s %s\n' "CPU" "Host CPU packages" "$host_pkgs" "Windows host"
  [[ -n "$host_mem" ]] && printf '%-14s %-24s %-34s %s\n' "Memory" "Host physical" "${host_mem} GiB" "Windows total RAM"
  printf '%-14s %-24s %-34s %s\n' "Memory" "WSL visible limit" "$(human_bytes "$mem_total")" "limit exposed to this distro"
  printf '%-14s %-24s %-34s %s\n' "Memory" "WSL used/available" "$(human_bytes "$mem_used") / $(human_bytes "$mem_avail")" "used / available"

  echo
  printf '%-8s %-8s %-8s %-8s %-8s %-s\n' "SOURCE" "SIZE" "USED" "AVAIL" "USE%" "MOUNT"
  printf '%-8s %-8s %-8s %-8s %-8s %-s\n' "------" "----" "----" "-----" "----" "-----"
  df -hT -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 { printf "%-8s %-8s %-8s %-8s %-8s %-s\n", "WSL", $3, $4, $5, $6, $7 }' | head -8
  root_line="$(df -h / 2>/dev/null | awk 'NR==2 { print $2 "|" $3 "|" $4 "|" $5 "|" $6 }')"
  [[ -z "$root_line" ]] && echo "WSL      unknown  unknown  unknown  unknown  /"

  local disks
  disks="$(host_disks)"
  if [[ -n "$disks" ]]; then
    printf '%s\n' "$disks" | awk -F'|' 'NF == 4 { printf "%-8s %-8s %-8s %-8s %-8s %-s\n", "Windows", $2 "G", $3 "G", $4 "G", "-", $1 }'
  fi
}

wsl_status_value() {
  local pattern="$1"
  local file="$WSL_PS_OUT/01-wsl-status.txt"
  [[ -f "$file" ]] || return 1
  awk -F': ' -v p="$pattern" '$1 == p { print $2; exit }' "$file"
}

render_wsl2_info() {
  local distro kernel uptime wsl_version windows_version default_version ps_status default_distro
  distro="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null)"
  kernel="$(uname -r)"
  uptime="$(uptime -p 2>/dev/null || uptime)"
  default_distro="$(wsl_status_value "Default Distribution" || true)"
  default_version="$(wsl_status_value "Default Version" || true)"
  wsl_version="$(wsl_status_value "WSL version" || true)"
  windows_version="$(wsl_status_value "Windows version" || true)"
  ps_status="available"
  if ! wi_have powershell.exe && ! wi_have pwsh.exe && ! wi_have pwsh; then
    ps_status="missing"
  fi

  section_title "WSL2 INFO"
  print_kv_table_header
  printf '%-14s %-24s %-34s %s\n' "Linux" "Distro" "${distro:-unknown}" "current distro"
  printf '%-14s %-24s %-34s %s\n' "Linux" "Kernel" "$kernel" "uname -r"
  printf '%-14s %-24s %-34s %s\n' "Linux" "Uptime" "$uptime" "current session"
  [[ -n "$default_distro" ]] && printf '%-14s %-24s %-34s %s\n' "WSL" "Default distro" "$default_distro" "wsl.exe --status"
  [[ -n "$default_version" ]] && printf '%-14s %-24s %-34s %s\n' "WSL" "Default version" "$default_version" "wsl.exe --status"
  [[ -n "$wsl_version" ]] && printf '%-14s %-24s %-34s %s\n' "WSL" "WSL version" "$wsl_version" "wsl.exe --version"
  [[ -n "$windows_version" ]] && printf '%-14s %-24s %-34s %s\n' "Windows" "Windows version" "$windows_version" "host"
  printf '%-14s %-24s %-34s %s\n' "Windows" "PowerShell" "$ps_status" "interop"
}

gpu_memory_for_pid() {
  local pid="$1"
  if wi_have nvidia-smi; then
    nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null |
      awk -F, -v pid="$pid" '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($1 == pid && $2 ~ /^[0-9]+$/) { print $2 " MiB"; exit } }'
  elif [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
    /usr/lib/wsl/lib/nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null |
      awk -F, -v pid="$pid" '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($1 == pid && $2 ~ /^[0-9]+$/) { print $2 " MiB"; exit } }'
  fi
}

render_top_cpu() {
  section_title "HIGH CPU PROCESSES"
  printf '%-8s %-12s %-5s %-7s %-7s %-10s %-s\n' "PID" "USER" "THR" "CPU%" "MEM%" "GPU" "CMD"
  printf '%-8s %-12s %-5s %-7s %-7s %-10s %-s\n' "---" "----" "---" "----" "----" "---" "---"
  ps -eo pid,user,nlwp,pcpu,pmem,comm --sort=-pcpu --no-headers 2>/dev/null |
    awk '$6 !~ /^(ps|awk|head|tee)$/ && $6 !~ /(collect-status|wsl2-info)/ { print; count++; if (count == 5) exit }' |
    while read -r pid user thr cpu mem comm; do
      local gpu
      gpu="$(gpu_memory_for_pid "$pid")"
      [[ -z "$gpu" ]] && gpu="-"
      printf '%-8s %-12s %-5s %-7s %-7s %-10s %-s\n' "$pid" "$user" "$thr" "$cpu" "$mem" "$gpu" "$comm"
    done
}

render_package_health() {
  local file="$UBUNTU_OUT/07-package-health.txt"
  section_title "PACKAGE HEALTH"
  if [[ ! -f "$file" ]]; then
    echo "not collected in this focused run"
    return
  fi
  if grep -Eiq 'dependency problems|not fully installed|unconfigured|permission denied|unable to acquire|^E:' "$file"; then
    echo "CHECK: package check needs review: ubuntu-health/07-package-health.txt"
  elif grep -qi 'apt-get check skipped' "$file"; then
    echo "LIMITED: dpkg audit only; apt-get check skipped because collector does not invoke sudo"
  else
    echo "OK: no obvious dpkg audit issue"
  fi
}

render_network_info() {
  section_title "NETWORK INFO"
  printf '%-12s %-18s %-s\n' "SCOPE" "ITEM" "VALUE"
  printf '%-12s %-18s %-s\n' "-----" "----" "-----"
  ip -brief addr 2>/dev/null | awk '{ printf "%-12s %-18s %-s\n", "Linux", $1, substr($0, index($0,$3)) }'
  ip route show default 2>/dev/null | awk '{ printf "%-12s %-18s %-s\n", "Linux", "default-route", $0 }'
  awk '/^nameserver/ { printf "%-12s %-18s %-s\n", "Linux", "dns-server", $2 }' /etc/resolv.conf 2>/dev/null
  if timeout 3 ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
    printf '%-12s %-18s %-s\n' "Linux" "ping-1.1.1.1" "OK"
  else
    printf '%-12s %-18s %-s\n' "Linux" "ping-1.1.1.1" "CHECK"
  fi
  if getent hosts github.com >/dev/null 2>&1; then
    printf '%-12s %-18s %-s\n' "Linux" "dns-github.com" "OK"
  else
    printf '%-12s %-18s %-s\n' "Linux" "dns-github.com" "CHECK"
  fi

  local win_file="$WSL_PS_OUT/20-network-windows.txt"
  if [[ -f "$win_file" ]]; then
    if grep -q '### exit: 0' "$win_file"; then
      printf '%-12s %-18s %-s\n' "Windows" "network-capture" "OK: wsl2-powershell/20-network-windows.txt"
    elif grep -q '### exit: 124' "$win_file"; then
      printf '%-12s %-18s %-s\n' "Windows" "network-capture" "TIMEOUT: increase --timeout for full Windows network details"
    else
      printf '%-12s %-18s %-s\n' "Windows" "network-capture" "CHECK: wsl2-powershell/20-network-windows.txt"
    fi
  else
    printf '%-12s %-18s %-s\n' "Windows" "network-capture" "not collected"
  fi
}

render_ollama_gpu_info() {
  section_title "OLLAMA GPU INFO"
  printf '%-16s %-s\n' "ITEM" "VALUE"
  printf '%-16s %-s\n' "----" "-----"
  if command -v ollama >/dev/null 2>&1; then
    printf '%-16s %-s\n' "binary" "$(command -v ollama)"
    printf '%-16s %-s\n' "version" "$(ollama --version 2>/dev/null | head -1 || echo unknown)"
  else
    printf '%-16s %-s\n' "binary" "not found"
  fi
  if wi_http_get http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    printf '%-16s %-s\n' "api" "OK http://127.0.0.1:11434"
  else
    printf '%-16s %-s\n' "api" "CHECK http://127.0.0.1:11434"
  fi
  if command -v ollama >/dev/null 2>&1; then
    echo
    echo "Running models:"
    local models
    models="$(ollama ps 2>/dev/null | sed -n '1,6p' || true)"
    if [[ "$(printf '%s\n' "$models" | sed '/^[[:space:]]*$/d' | wc -l)" -le 1 ]]; then
      echo "none visible"
    else
      printf '%s\n' "$models"
    fi
  fi
  echo
  echo "GPU snapshot:"
  if wi_have nvidia-smi; then
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null |
      awk -F, '{ for (i=1; i<=5; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i); printf "GPU: %s | memory: %s / %s | util: %s | temp: %sC\n", $1, $2, $3, $4, $5 }'
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
      awk -F, 'BEGIN { printed=0 } /ollama/ { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); printf "Ollama GPU process: pid=%s memory=%s name=%s\n", $1, $3, $2; printed=1 } END { if (!printed) print "Ollama GPU process: none visible" }'
  elif [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
    /usr/lib/wsl/lib/nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null |
      awk -F, '{ for (i=1; i<=5; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i); printf "GPU: %s | memory: %s / %s | util: %s | temp: %sC\n", $1, $2, $3, $4, $5 }'
    /usr/lib/wsl/lib/nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
      awk -F, 'BEGIN { printed=0 } /ollama/ { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); printf "Ollama GPU process: pid=%s memory=%s name=%s\n", $1, $3, $2; printed=1 } END { if (!printed) print "Ollama GPU process: none visible" }'
  else
    echo "nvidia-smi not found"
  fi
}

render_collector_runtimes() {
  section_title "COLLECTOR RUNTIMES"
  printf '%-21s %7s   %s\n' "COLLECTOR" "TIME" "STATUS"
  printf '%-21s %7s   %s\n' "---------" "----" "------"
  metadata_line "$UBUNTU_OUT"
  metadata_line "$WSL_SHELL_OUT"
  metadata_line "$WSL_PS_OUT"
}

render_artifacts() {
  section_title "ARTIFACTS"
  printf '%-12s %s\n' "directory:" "$OUT"
  if [[ -n "${ZIP_STATUS:-}" ]]; then
    printf '%-12s %s\n' "zip:" "$ZIP_STATUS"
  fi
}

render_critical_errors() {
  section_title "CRITICAL ERRORS"
  local failed_count crit_count
  failed_count="$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)"
  crit_count="$(journalctl -q -p 2 --since "5 minutes ago" --no-pager 2>/dev/null | grep -c . || true)"
  echo "failed systemd units: $failed_count"
  echo "critical events in last 5 minutes: $crit_count"
  if [[ "$failed_count" -gt 0 ]]; then
    echo
    systemctl --failed --no-pager 2>/dev/null || true
  fi
  if [[ "$crit_count" -gt 0 ]]; then
    echo
    journalctl -q -p 2 --since "5 minutes ago" --no-pager -o short-iso 2>/dev/null || true
  fi
}

render_all_errors() {
  [[ "$DO_ERROR" -eq 1 ]] || return 0
  section_title "ERROR CLASSES SINCE BOOT"

  local errors
  errors="$(journalctl -q -p 3 -b --no-pager -o short-iso 2>/dev/null || true)"
  if [[ -z "$errors" ]]; then
    echo "none found, or journal unavailable"
    return 0
  fi

  printf '%-34s %6s  %s\n' "CLASS" "COUNT" "LATEST"
  printf '%-34s %6s  %s\n' "-----" "-----" "------"
  printf '%s\n' "$errors" |
    awk '
      BEGIN {
        order[1] = "WSL GPU/dxg ioctl"
        order[2] = "WSL DNS resolver"
        order[3] = "WSL init/systemd startup"
        order[4] = "Host firmware/PCI"
        order[5] = "Other WSL errors"
        order[6] = "Other kernel errors"
        order[7] = "Other journal errors"
      }
      function classify(line) {
        if (line ~ /misc dxg: dxgk:/) return "WSL GPU/dxg ioctl"
        if (line ~ /CheckConnection: getaddrinfo/) return "WSL DNS resolver"
        if (line ~ /WaitForBootProcess|\/sbin\/init failed/) return "WSL init/systemd startup"
        if (line ~ /\[Firmware Bug\]|PCI: Fatal/) return "Host firmware/PCI"
        if (line ~ / WSL \(/) return "Other WSL errors"
        if (line ~ / kernel:/) return "Other kernel errors"
        return "Other journal errors"
      }
      function trim_message(line) {
        sub(/^[0-9TZ:+.-]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", line)
        return line
      }
      function remember(class, line) {
        message_count[class, line]++
        if (seen[class, line]) return
        seen[class, line] = 1
        sample[class, 1] = sample[class, 2]
        sample[class, 2] = sample[class, 3]
        sample[class, 3] = line
      }
      function emit(class) {
        if (!(class in count)) return
        printf "%-34s %6d  %s\n", class, count[class], latest[class]
      }
      {
        class = classify($0)
        count[class]++
        latest[class] = $1
        remember(class, trim_message($0))
      }
      END {
        emit("WSL GPU/dxg ioctl")
        emit("WSL DNS resolver")
        emit("WSL init/systemd startup")
        emit("Host firmware/PCI")
        emit("Other WSL errors")
        emit("Other kernel errors")
        emit("Other journal errors")
        print ""
        print "Examples:"
        for (i = 1; i <= 7; i++) {
          class = order[i]
          if (!(class in count)) continue
          print class ":"
          for (j = 1; j <= 3; j++) {
            if (sample[class, j] != "") {
              message = sample[class, j]
              printf "  - [%dx] %s\n", message_count[class, message], message
            }
          }
        }
      }
    '
}

render_report() {
  echo "=== WSL2 INFO REPORT ==="
  printf '%-14s %s\n' "profile:" "$PROFILE"
  printf '%-14s %s\n' "started:" "$GLUE_START_ISO"
  printf '%-14s %s\n' "finished:" "$(date -Is)"
  printf '%-14s %s s\n' "elapsed:" "$(wi_elapsed_seconds "$GLUE_START_MS")"
  printf '%-14s %s\n' "timeout:" "${TIMEOUT_VALUE}s per collector"

  case "$FOCUS" in
    network)
      render_network_info
      render_collector_runtimes
      render_artifacts
      ;;
    ollama)
      render_ollama_gpu_info
      render_collector_runtimes
      render_artifacts
      ;;
    all)
      render_hardware_info
      render_wsl2_info
      render_network_info
      render_ollama_gpu_info
      render_top_cpu
      render_package_health
      render_collector_runtimes
      render_artifacts
      ;;
    *)
      render_hardware_info
      render_wsl2_info
      [[ "$DO_NET" -eq 1 ]] && render_network_info
      [[ "$DO_OLLAMA" -eq 1 ]] && render_ollama_gpu_info
      render_top_cpu
      render_package_health
      render_collector_runtimes
      render_artifacts
      ;;
  esac

  render_critical_errors
  render_all_errors
}

ZIP_STATUS="not created; zip command is not installed"
if wi_have zip; then
  rm -f "$ZIPFILE"
  (cd "$OUT" && zip -qr "$ZIPFILE" .)
  SIZE="$(du -h "$ZIPFILE" | awk '{print $1}')"
  ZIP_STATUS="$ZIPFILE ($SIZE)"
fi

render_report | tee "$OUT/summary.txt"
