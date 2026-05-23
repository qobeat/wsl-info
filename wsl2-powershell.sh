#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=wsl2-info-lib.sh
. "$SCRIPT_DIR/wsl2-info-lib.sh"

usage() {
  cat <<'HELP'
wsl2-powershell.sh - Windows-side WSL2 collector through PowerShell

USAGE:
  wsl2-powershell.sh [--brief|--full] [--network] [--timeout SECONDS] [--output-dir DIR]
  wsl2-powershell.sh --help

MODES:
  --brief   Windows version, WSL status/version, and distro list.
  --full    Brief + Windows .wslconfig and command discovery details.

DEFAULTS:
  mode: brief
  timeout: 10 seconds in brief mode, 60 seconds in full mode

NOTES:
  This script is intended to be launched from WSL2. It does not require admin rights.
HELP
}

MODE="brief"
DO_NET=0
OUT=""
TIMEOUT_VALUE=""
MS_PS="https://raw.githubusercontent.com/microsoft/WSL/master/diagnostics/collect-wsl-logs.ps1"
MS_WPRP="https://raw.githubusercontent.com/microsoft/WSL/master/diagnostics/wsl.wprp"

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
    *) wi_die "unknown option for wsl2-powershell.sh: $1" ;;
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
  OUT="$HOME/tmp/wsl2-powershell-$PROFILE-$(date +%Y%m%d-%H%M%S)"
fi

wi_init_run "wsl2-powershell.sh" "$OUT" "$MODE" "$TIMEOUT_VALUE"
trap wi_finish_run EXIT
trap 'wi_finish_run; exit 143' TERM
trap 'wi_finish_run; exit 130' INT

cat >"$WI_OUT/RUN-MICROSOFT-WSL-COLLECTOR-AS-ADMIN.ps1" <<EOF
Invoke-WebRequest -UseBasicParsing "$MS_PS" -OutFile collect-wsl-logs.ps1
Set-ExecutionPolicy Bypass -Scope Process -Force
.\collect-wsl-logs.ps1
EOF

cat >"$WI_OUT/RUN-MICROSOFT-WSL-NETWORK-COLLECTOR-AS-ADMIN.ps1" <<EOF
Invoke-WebRequest -UseBasicParsing "$MS_PS" -OutFile collect-wsl-logs.ps1
Set-ExecutionPolicy Bypass -Scope Process -Force
.\collect-wsl-logs.ps1 -LogProfile networking
EOF

cat >"$WI_OUT/README-OFFICIAL-WSL-COLLECTOR.txt" <<EOF
Official Microsoft WSL collector requires Administrator PowerShell:
$MS_PS

Network profile helper:
.\collect-wsl-logs.ps1 -LogProfile networking
EOF

wi_run_capture "01-wsl-status.txt" "wi_powershell 'wsl.exe --status; Write-Output \"\"; wsl.exe --version; Write-Output \"\"; wsl.exe -l -v'"
wi_run_capture "02-windows-version.txt" "wi_powershell '[System.Environment]::OSVersion.VersionString'"

if [[ "$MODE" == "full" ]]; then
  wi_run_capture "03-windows-version-full.txt" "wi_powershell 'Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime | Format-List'"
  wi_run_capture "04-wsl-windows-config-full.txt" "wi_powershell 'Write-Output \"=== .wslconfig ===\"; if (Test-Path ([IO.Path]::Combine([Environment]::GetFolderPath(\"UserProfile\"), \".wslconfig\"))) { Get-Content ([IO.Path]::Combine([Environment]::GetFolderPath(\"UserProfile\"), \".wslconfig\")) } else { Write-Output \"No .wslconfig found\" }; Write-Output \"\"; Write-Output \"=== Command discovery ===\"; Get-Command wsl.exe,powershell.exe | Format-List Name,Source,Version'"
fi

if [[ "$DO_NET" -eq 1 ]]; then
  wi_run_capture "20-network-windows.txt" "wi_powershell 'Write-Output \"=== Get-NetIPConfiguration ===\"; Get-NetIPConfiguration | Format-List; Write-Output \"\"; Write-Output \"=== DNS servers ===\"; Get-DnsClientServerAddress | Format-Table -AutoSize; Write-Output \"\"; Write-Output \"=== Routes ===\"; Get-NetRoute | Sort-Object RouteMetric,DestinationPrefix | Select-Object -First 120 | Format-Table -AutoSize; Write-Output \"\"; Write-Output \"=== Test-NetConnection github.com:443 ===\"; Test-NetConnection github.com -Port 443; Write-Output \"\"; Write-Output \"=== ipconfig /all ===\"; ipconfig.exe /all; Write-Output \"\"; Write-Output \"=== route print ===\"; route.exe print'"
fi

wi_download_capture "90-download-collect-wsl-logs.txt" "$MS_PS" "$WI_OUT/collect-wsl-logs.ps1"
[[ "$DO_NET" -eq 1 ]] && wi_download_capture "91-download-wsl-wprp.txt" "$MS_WPRP" "$WI_OUT/wsl.wprp"
