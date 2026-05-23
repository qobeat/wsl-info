#!/usr/bin/env bash
set -u

usage() { cat <<'HELP'
collect-status.sh - compact WSL2 health collector

USAGE:
  collect-status.sh --brief [--network] [--ollama]
  collect-status.sh --full  [--network] [--ollama]
  collect-status.sh --network
  collect-status.sh --ollama
  collect-status.sh --help

DEFAULT:
  No arguments: show this help only.

MODES:
  --brief   Core summary, current performance, package sanity, last 5 min events.
  --full    Brief + events since boot, full package list, full systemd unit list.
  --network Add WSL/DNS/route/listener/connectivity checks and official network helper.
  --ollama  Add Ollama process/API/model/GPU checks. Does not run inference.

OUTPUT:
  ~/tmp/collect-status-<options>-<yyyy-mm-dd>.zip

NOTES:
  No sudo is used. apt-get check is run only with passwordless sudo.
  Official Microsoft WSL log collector is Windows-side PowerShell/admin.
HELP
}

[[ $# -eq 0 ]] && usage && exit 0
MODE=""; DO_NET=0; DO_OLLAMA=0
for a in "$@"; do case "$a" in
  --brief) MODE="brief";; --full) MODE="full";; --network) DO_NET=1;; --ollama) DO_OLLAMA=1;;
  -h|--help) usage; exit 0;; *) echo "ERROR: unknown option: $a"; echo; usage; exit 2;;
esac; done
[[ -z "$MODE" ]] && MODE="brief"

DATE="$(date +%F)"; STAMP="$(date +%Y%m%d-%H%M%S)"; ROOT="$HOME/tmp"
PROFILE="$MODE"; [[ $DO_NET -eq 1 ]] && PROFILE="$PROFILE-network"; [[ $DO_OLLAMA -eq 1 ]] && PROFILE="$PROFILE-ollama"
OUT="$ROOT/collect-status-$PROFILE-$STAMP"; ZIPFILE="$ROOT/collect-status-$PROFILE-$DATE.zip"
MS_PS="https://raw.githubusercontent.com/microsoft/WSL/master/diagnostics/collect-wsl-logs.ps1"
MS_NET="https://raw.githubusercontent.com/microsoft/WSL/master/diagnostics/networking.sh"
MS_WPRP="https://raw.githubusercontent.com/microsoft/WSL/master/diagnostics/wsl.wprp"
mkdir -p "$OUT"

have(){ command -v "$1" >/dev/null 2>&1; }
run(){ local f="$1"; shift; { echo "### time: $(date -Is)"; echo "### command: $*"; echo; timeout 120 bash -lc "$*"; rc=$?; echo; echo "### exit: $rc"; } >"$OUT/$f" 2>&1 || true; }
http_get(){ local u="$1"; if have curl; then curl -fsS --max-time 5 "$u"; elif have python3; then python3 - "$u" <<'PY'
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=5) as r: print(r.read().decode('utf-8','replace'))
PY
else return 127; fi; }
download(){ local u="$1" o="$2"; if have curl; then curl -fsSL --max-time 12 -o "$o" "$u"; elif have python3; then python3 - "$u" "$o" <<'PY'
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
else return 127; fi; }

cat >"$OUT/RUN-MICROSOFT-WSL-COLLECTOR-AS-ADMIN.ps1" <<EOF2
Invoke-WebRequest -UseBasicParsing "$MS_PS" -OutFile collect-wsl-logs.ps1
Set-ExecutionPolicy Bypass -Scope Process -Force
.\collect-wsl-logs.ps1
EOF2
cat >"$OUT/RUN-MICROSOFT-WSL-NETWORK-COLLECTOR-AS-ADMIN.ps1" <<EOF2
Invoke-WebRequest -UseBasicParsing "$MS_PS" -OutFile collect-wsl-logs.ps1
Set-ExecutionPolicy Bypass -Scope Process -Force
.\collect-wsl-logs.ps1 -LogProfile networking
EOF2
cat >"$OUT/README-OFFICIAL-WSL-COLLECTOR.txt" <<EOF2
Official Microsoft WSL collector requires Administrator PowerShell:
$MS_PS
Network profile helper:
.\collect-wsl-logs.ps1 -LogProfile networking
EOF2
download "$MS_PS" "$OUT/collect-wsl-logs.ps1" >/dev/null 2>&1 || true
[[ $DO_NET -eq 1 ]] && download "$MS_NET" "$OUT/networking.sh" >/dev/null 2>&1 || true
[[ $DO_NET -eq 1 ]] && download "$MS_WPRP" "$OUT/wsl.wprp" >/dev/null 2>&1 || true

run "00-wsl-release.txt" 'uname -a; echo; cat /etc/os-release 2>/dev/null; echo; cat /proc/version; echo; systemd-detect-virt 2>/dev/null || true; echo; uptime; echo; command -v inxi >/dev/null && inxi -Fazy 2>/dev/null || echo "inxi not installed; built-in WSL inventory used instead"'
run "01-windows-wsl-status.txt" 'cmd.exe /c ver 2>&1 | tr -d "\000\r"; echo; wsl.exe --status 2>&1 | tr -d "\000\r"; echo; wsl.exe --version 2>&1 | tr -d "\000\r"; echo; wsl.exe -l -v 2>&1 | tr -d "\000\r"'
run "02-cpu-memory.txt" 'lscpu 2>/dev/null; echo; free -h; echo; grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree" /proc/meminfo'
run "03-disk-filesystems.txt" 'df -hT; echo; lsblk -f 2>/dev/null || true; echo; mount | sort; echo; du -sh "$HOME" 2>/dev/null || true'
run "04-processes-listeners.txt" 'ps -eo pid,ppid,stat,etime,%cpu,%mem,comm,args --sort=-%cpu | awk "NR==1 || (\$7!=\"ps\" && \$0 !~ /collect-status.sh/)" | head -80; echo; ss -tulpen 2>&1 | head -400'
if have lsof; then run "05-lsof.txt" 'lsof -nP -i 2>&1 | head -800; echo; lsof -nP -iTCP -sTCP:LISTEN 2>&1'; else echo 'lsof not installed; optional: sudo apt install lsof' >"$OUT/05-lsof.txt"; fi
run "06-performance-gpu.txt" 'vmstat 1 3; echo; command -v iostat >/dev/null && iostat -xz 1 2 || echo "iostat not available"; echo; if command -v nvidia-smi >/dev/null; then nvidia-smi; elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then /usr/lib/wsl/lib/nvidia-smi; else echo "nvidia-smi not found"; fi'
run "07-package-health.txt" 'dpkg --audit; echo; if sudo -n true 2>/dev/null; then sudo -n apt-get check; else echo "apt-get check skipped: no passwordless sudo"; fi; echo; echo "dpkg -V sample:"; dpkg -V 2>&1 | head -300 || true; if command -v debsums >/dev/null; then echo; echo "debsums sample:"; debsums -s 2>&1 | head -300; fi'
run "08-services-events.txt" 'systemctl --failed --no-pager 2>/dev/null || true; echo; journalctl -p 3 --since "5 minutes ago" --no-pager -o short-iso 2>/dev/null | tail -300; echo; journalctl -k --since "5 minutes ago" --no-pager -o short-iso 2>/dev/null | tail -300'

if [[ "$MODE" == "full" ]]; then
  run "09-events-since-boot.txt" 'journalctl -b --no-pager -o short-iso 2>/dev/null; echo; journalctl -p 3 -xb --no-pager -o short-iso 2>/dev/null; echo; journalctl -k -b --no-pager -o short-iso 2>/dev/null'
  run "10-package-list-full.txt" 'echo "=== manual packages ==="; apt-mark showmanual | sort; echo; echo "=== installed packages ==="; dpkg-query -W -f="${Package}\t${Version}\t${Architecture}\n" | sort'
  run "11-systemd-units-full.txt" 'systemctl list-units --all --no-pager 2>/dev/null || true'
fi

if [[ $DO_NET -eq 1 ]]; then
  run "20-network-health.txt" 'echo "=== Linux network ==="; ip -brief addr; echo; ip route; echo; ip neigh show 2>/dev/null || true; echo; cat /etc/resolv.conf; echo; [ -f /etc/wsl.conf ] && cat /etc/wsl.conf || true; echo; echo "=== DNS ==="; getent hosts github.com microsoft.com ubuntu.com || true; echo; echo "=== ping ==="; ping -c 2 -W 2 1.1.1.1 || true; ping -c 2 -W 2 github.com || true; echo; echo "=== Windows ipconfig ==="; ipconfig.exe /all 2>&1 | tr -d "\000\r" | head -300; echo; echo "=== Windows route ==="; route.exe print 2>&1 | tr -d "\000\r" | head -250'
fi

if [[ $DO_OLLAMA -eq 1 ]]; then
  { echo "### time: $(date -Is)"; echo "=== Ollama binary/process ==="; command -v ollama || true; ollama --version 2>&1 || true; pgrep -a ollama || true; echo; echo "=== Listen/API ==="; ss -ltnp 2>/dev/null | grep -E "(:11434|ollama)" || true; http_get http://127.0.0.1:11434/api/version || true; echo; echo "=== Local models ==="; ollama list 2>&1 || true; http_get http://127.0.0.1:11434/api/tags || true; echo; echo "=== Running models ==="; ollama ps 2>&1 || true; http_get http://127.0.0.1:11434/api/ps || true; echo; echo "=== Model disk ==="; du -sh ~/.ollama ~/.ollama/models ~/.ollama/models/blobs 2>/dev/null || true; du -h ~/.ollama/models/blobs/* 2>/dev/null | sort -h | tail -25 || true; echo; echo "=== GPU ==="; if command -v nvidia-smi >/dev/null; then nvidia-smi; elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then /usr/lib/wsl/lib/nvidia-smi; fi; } >"$OUT/30-ollama-health.txt" 2>&1 || true
fi

DISTRO="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)"
MEM="$(free -h | awk '/^Mem:/{print $3 " used / " $2 " total; " $7 " available"}')"
DISK="$(df -h / | awk 'NR==2{print $5 " used; " $4 " free on /"}')"
FAILS="$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)"
ERR5="$(journalctl -p 3 --since "5 minutes ago" --no-pager 2>/dev/null | grep -c . || true)"
PKG="No obvious dpkg audit issue"; grep -qi 'apt-get check skipped' "$OUT/07-package-health.txt" && PKG="Limited: dpkg audit only; apt-get check needs sudo"; grep -Eiq 'dependency problems|not fully installed|unconfigured|permission denied|unable to acquire|^E:' "$OUT/07-package-health.txt" && PKG="Package check needs review: see 07-package-health.txt"
NETSUM=""; [[ $DO_NET -eq 1 ]] && timeout 3 ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && NETSUM="network-ip: OK" || [[ $DO_NET -eq 1 ]] && NETSUM="network-ip: CHECK"
OLLSUM=""; [[ $DO_OLLAMA -eq 1 ]] && http_get http://127.0.0.1:11434/api/version >/dev/null 2>&1 && OLLSUM="ollama-api: OK" || [[ $DO_OLLAMA -eq 1 ]] && OLLSUM="ollama-api: CHECK"
{
  echo "=== WSL2 HEALTH SUMMARY ==="; echo "profile: $PROFILE"; echo "time: $(date -Is)"; echo "distro: ${DISTRO:-unknown}"; echo "kernel: $(uname -r)"; echo "uptime: $(uptime -p 2>/dev/null || uptime)"; echo "memory: $MEM"; echo "disk: $DISK"; echo "failed systemd units: $FAILS"; echo "last-5-min critical/error events: $ERR5"; [[ -n "$NETSUM" ]] && echo "$NETSUM"; [[ -n "$OLLSUM" ]] && echo "$OLLSUM"; echo; echo "Top CPU processes:"; ps -eo pid,%cpu,%mem,comm,args --sort=-%cpu | awk 'NR==1 || ($4!="ps" && $4!="awk" && $4!="head" && $4!="tee" && $0 !~ /collect-status.sh/)' | head -8; echo; echo "Package health:"; echo "$PKG";
} | tee "$OUT/summary.txt"

rm -f "$ZIPFILE"; (cd "$OUT" && zip -qr "$ZIPFILE" .); SIZE="$(du -h "$ZIPFILE" | awk '{print $1}')"
echo; echo "ZIP: $ZIPFILE"; echo "SIZE: $SIZE"; echo "Collected directory: $OUT"
