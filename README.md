# wsl-info

`wsl-info` is a small Bash-based diagnostics package for collecting WSL2 and Ubuntu health information without requiring root access. It is designed for quick local triage, repeatable bug reports, and shareable troubleshooting bundles when a WSL2 environment feels slow, broken, misconfigured, or hard to explain.

The package splits collection into focused scripts:

- Ubuntu health checks that can run on any Ubuntu system.
- WSL2 Linux-side checks that inspect the distro from inside WSL.
- WSL2 Windows-side checks that call PowerShell and `wsl.exe`.
- A glue script that runs the collectors, prints a summary, and creates a zip bundle.

The main entrypoint is `wsl2-info.sh`.

## Quick Start

Run a brief WSL2 health collection:

```bash
./wsl2-info.sh --brief
```

Run a full collection:

```bash
./wsl2-info.sh --full
```

Include network and Ollama checks:

```bash
./wsl2-info.sh --brief --network --ollama
```

Run focused network or Ollama views:

```bash
./wsl2-info.sh --network
./wsl2-info.sh --ollama
```

Collect everything and print grouped error classes at the end:

```bash
./wsl2-info.sh --all
```

Use a custom per-collector timeout:

```bash
./wsl2-info.sh --brief --timeout 20
```

Write output to a specific directory:

```bash
./wsl2-info.sh --full --output-dir /tmp/wsl2-info-full
```

## Goals

`wsl-info` is meant to answer practical questions quickly:

- Is WSL2 itself healthy and running the expected version?
- Is the Ubuntu distro seeing normal CPU, memory, disk, process, listener, service, and journal state?
- Are WSL interop, mounts, `/etc/wsl.conf`, DNS, routes, and Windows networking behaving as expected?
- Is an optional local Ollama service reachable, using GPU, and seeing its models?
- What should be attached to a support ticket or GitHub issue when the problem is intermittent?

The scripts avoid privileged writes and do not invoke `sudo`. `apt-get check` runs only when `ubuntu-health.sh` itself is already running as root.

## Files

### `wsl2-info.sh`

The main glue script. It runs the Ubuntu, WSL Linux-side, and WSL PowerShell collectors with the same mode and timeout settings, prints a screen summary, and creates a zip archive when `zip` is installed.

Use this script for normal WSL2 diagnostics.

```bash
./wsl2-info.sh --brief
./wsl2-info.sh --full
./wsl2-info.sh --brief --network
./wsl2-info.sh --brief --ollama
./wsl2-info.sh --brief --network --ollama --timeout 30
./wsl2-info.sh --all
```

By default, output is written below:

```text
~/tmp/wsl2-info-<profile>-<timestamp>/
~/tmp/wsl2-info-<profile>-<yyyy-mm-dd>.zip
```

The screen report is sectioned. Each collector progress line includes its start timestamp and elapsed seconds, and the report header includes the overall collection start, finish, and elapsed time. Normal brief/full reports show `HARDWARE INFO`, `WSL2 INFO`, compact high-CPU processes, package health, collector runtimes, artifacts, and critical errors at the end. Focused `--network` and `--ollama` runs show only their relevant diagnostics plus runtimes, artifacts, and the final error section.

### `ubuntu-health.sh`

The WSL2-agnostic Ubuntu health collector. It can be run on any Ubuntu system, including non-WSL machines.

It collects:

- OS, kernel, virtualization, and uptime details.
- CPU and memory information.
- Disk, filesystem, mount, and block-device information.
- Process and listener snapshots.
- Optional `lsof` listener data.
- Basic performance and GPU information through `vmstat`, optional `iostat`, and `nvidia-smi`.
- Package health through `dpkg --audit` and `apt-get check` only when already running as root.
- Failed systemd units and recent journal/kernel errors.
- In full mode, boot-wide journals, installed packages, manual packages, and all systemd units.
- With `--ollama`, local Ollama binary, process, API, model, disk, running model, and GPU checks.

Use this script when the problem may be ordinary Ubuntu health rather than WSL-specific behavior.

```bash
./ubuntu-health.sh --brief
./ubuntu-health.sh --full
./ubuntu-health.sh --brief --ollama
./ubuntu-health.sh --brief --timeout 15 --output-dir /tmp/ubuntu-health
```

### `wsl2-shell.sh`

The Linux-side WSL2 collector. It runs inside the WSL distro and captures WSL-specific state visible from Linux.

It collects:

- Kernel and `/proc/version` WSL details.
- Virtualization detection.
- WSL environment variables such as `WSL_DISTRO_NAME`, `WSL_INTEROP`, and `WSLENV`.
- `/etc/wsl.conf`.
- WSL interop registration.
- WSL-related mounts, `/mnt`, and `/etc/fstab`.
- In full mode, selected display/session environment variables and WSL runtime paths.
- With `--network`, Linux-side interfaces, routes, neighbors, resolver config, DNS lookup, and ping checks.

Use this script when Windows interop, WSL mounts, DNS generation, `/etc/wsl.conf`, or Linux-side networking are under suspicion.

```bash
./wsl2-shell.sh --brief
./wsl2-shell.sh --full
./wsl2-shell.sh --brief --network
./wsl2-shell.sh --brief --network --output-dir /tmp/wsl2-shell
```

When `--network` is used, the script also attempts to download Microsoft's official Linux-side WSL networking helper into the output directory for review.

### `wsl2-powershell.sh`

The Windows-side WSL2 collector. It is launched from WSL and uses PowerShell plus `wsl.exe` to capture Windows-visible WSL state.

It collects:

- `wsl.exe --status`.
- `wsl.exe --version`.
- `wsl.exe -l -v`.
- Windows version string.
- In full mode, Windows OS details, `.wslconfig`, and command discovery details.
- With `--network`, Windows-side IP configuration, DNS server configuration, routes, connectivity tests, `ipconfig /all`, and `route print`.
- Microsoft WSL collector helper files and small PowerShell scripts showing how to run the official collector as Administrator.

Use this script when the problem depends on the Windows host view of WSL, WSL versioning, distro registration, host networking, or `.wslconfig`.

```bash
./wsl2-powershell.sh --brief
./wsl2-powershell.sh --full
./wsl2-powershell.sh --brief --network
./wsl2-powershell.sh --brief --timeout 30 --output-dir /tmp/wsl2-powershell
```

This script does not require Administrator rights. The generated Microsoft collector helper scripts are instructions for a separate Administrator PowerShell session.

### `wsl2-info-lib.sh`

Shared Bash utility functions used by the collector scripts.

It provides:

- Command discovery helpers.
- Mode and timeout validation.
- Collector start/end metadata writing.
- Per-command capture with remaining runtime enforcement.
- HTTP download helpers using `curl` or Python.
- PowerShell invocation and Windows output cleanup.
- GPU discovery through `nvidia-smi`.

This file is sourced by the other scripts and is not normally run directly.

### `collect-status.sh`

Compatibility wrapper for older usage. It forwards all arguments to `wsl2-info.sh`.

```bash
./collect-status.sh --brief
./collect-status.sh --brief --network --ollama
```

## Modes

### Brief Mode

Brief mode is the default operational triage mode. It captures the highest-signal checks while avoiding slower inventory work.

```bash
./wsl2-info.sh --brief
```

Use brief mode when:

- You want a quick snapshot before and after changing WSL settings.
- You are collecting information for a bug report.
- You want to avoid large logs and package inventories.
- You are running checks repeatedly while debugging.

### Full Mode

Full mode adds larger inventories and logs.

```bash
./wsl2-info.sh --full
```

Use full mode when:

- Brief mode did not explain the issue.
- You need boot-wide journal data.
- You need a full package list or systemd unit list.
- You are preparing a more complete support bundle.

## Optional Checks

### Network Checks

Network checks are enabled with `--network`.

```bash
./wsl2-info.sh --brief --network
./wsl2-info.sh --network
```

With `--brief` or `--full`, this adds network sections to the normal report. When `--network` is used by itself, the screen report is focused on network diagnostics only. It is useful for DNS failures, unreachable services, slow downloads, VPN issues, proxy problems, and WSL host/guest routing confusion.

### Ollama Checks

Ollama checks are enabled with `--ollama`.

```bash
./wsl2-info.sh --brief --ollama
./wsl2-info.sh --ollama
```

With `--brief` or `--full`, this adds Ollama GPU visibility to the normal report. When `--ollama` is used by itself, the screen report is focused on Ollama/GPU runtime state only. It does not run inference.

### Error Output

Critical errors are always printed as the last normal section of the report. Use `--error` to print grouped journal error classes since boot at the very end:

```bash
./wsl2-info.sh --brief --error
./wsl2-info.sh --network --error
```

### All Output

Use `--all` to run full collection, include network and Ollama checks, and print all errors at the end:

```bash
./wsl2-info.sh --all
./wsl2-info.sh --all --timeout 120
```

## Timeouts

Each collector has its own runtime budget.

- Brief mode default: `10` seconds per collector.
- Full mode default: `60` seconds per collector.
- Override with `--timeout SECONDS`.
- Use `--timeout 0` for no collector runtime limit.

Examples:

```bash
./wsl2-info.sh --brief --timeout 20
./ubuntu-health.sh --full --timeout 120
./wsl2-powershell.sh --brief --network --timeout 30
```

Each collector writes timing metadata to `00-run-metadata.txt` inside its output directory. If a collector exhausts its budget, metadata records `timed_out: yes`, and individual command files show whether commands were skipped or killed by timeout.

## Output Layout

A normal `wsl2-info.sh` run creates a directory like this:

```text
wsl2-info-brief-network-20260523-193000/
  00-run-metadata.txt
  child-runs.txt
  summary.txt
  ubuntu-health/
    00-run-metadata.txt
    01-ubuntu-release.txt
    ...
  wsl2-shell/
    00-run-metadata.txt
    01-wsl-linux-environment.txt
    ...
  wsl2-powershell/
    00-run-metadata.txt
    01-wsl-status.txt
    ...
```

If `zip` is installed, the same run also creates:

```text
~/tmp/wsl2-info-<profile>-<yyyy-mm-dd>.zip
```

The zip is convenient for attaching to an issue or sending to someone helping debug the system.

## Installation

Install into `~/.local/bin`:

```bash
mkdir -p ~/.local/bin
cp wsl2-info-lib.sh ubuntu-health.sh wsl2-shell.sh wsl2-powershell.sh wsl2-info.sh collect-status.sh ~/.local/bin/
chmod +x ~/.local/bin/ubuntu-health.sh ~/.local/bin/wsl2-shell.sh ~/.local/bin/wsl2-powershell.sh ~/.local/bin/wsl2-info.sh ~/.local/bin/collect-status.sh
```

Make sure `~/.local/bin` is on `PATH`:

```bash
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc ;;
esac
```

After opening a new shell:

```bash
wsl2-info.sh --brief
```

## Requirements

Required:

- Bash
- Standard Ubuntu userland tools
- `timeout` from GNU coreutils

Recommended:

- `zip` for archive creation.
- `curl` for downloading Microsoft helper scripts.
- `python3` as a fallback downloader.
- `lsof` for richer listener details.
- `sysstat` for `iostat`.
- `inxi` for expanded full-mode system inventory.
- `nvidia-smi` for GPU visibility.

Windows-side checks require one of:

- `powershell.exe`
- `pwsh.exe`
- `pwsh`

In normal WSL2 installs, `powershell.exe` and `wsl.exe` are available through Windows interop.

## Usage Cases

### Quick WSL Health Snapshot

```bash
wsl2-info.sh --brief
```

Use this first. It gives a concise screen summary and a bundle with the most useful health data.

### Debug DNS or Connectivity

```bash
wsl2-info.sh --network
```

Use this when WSL can start but DNS, Git, package downloads, browser callbacks, VPNs, or local service connectivity behave strangely.

### Debug Slow Ubuntu or High Resource Usage

```bash
ubuntu-health.sh --brief
ubuntu-health.sh --full --timeout 120
```

Use the standalone Ubuntu collector when the issue looks like CPU, memory, disk, process, package, service, or journal health rather than WSL integration.

### Debug Windows-Side WSL Configuration

```bash
wsl2-powershell.sh --full --timeout 60
```

Use this when the Windows host view matters: WSL version, distro list, `.wslconfig`, Windows networking, or official Microsoft collection handoff.

### Debug Ollama on WSL2

```bash
wsl2-info.sh --ollama
```

Use this when Ollama runs in WSL and you want process/API/model/GPU evidence without running an inference prompt.

### Create a Shareable Support Bundle

```bash
wsl2-info.sh --all --timeout 120
```

Use this when preparing a complete artifact for someone else to inspect.

## Safety and Privacy

The collectors capture local system configuration and runtime state. Review generated files before sharing.

Potentially sensitive data can include:

- Usernames and home paths.
- Process command lines.
- Mounted paths.
- Network addresses, DNS servers, routes, and adapter names.
- Package lists.
- Service and journal messages.
- Ollama model names and local model paths.
- Windows WSL configuration details.

The scripts do not intentionally collect secrets, browser history, SSH keys, or file contents outside targeted configuration and diagnostic commands, but command output can still include private paths or arguments.

## Troubleshooting

Show script help:

```bash
wsl2-info.sh --help
ubuntu-health.sh --help
wsl2-shell.sh --help
wsl2-powershell.sh --help
```

If the zip is not created, install `zip` or use the collected directory directly:

```bash
sudo apt install zip
```

If PowerShell checks are missing, verify Windows interop from WSL:

```bash
powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion'
wsl.exe --status
```

If a collector times out, rerun with a larger timeout:

```bash
wsl2-info.sh --brief --timeout 30
wsl2-info.sh --full --timeout 180
```

If package health is limited, the collector skipped `apt-get check` because it does not invoke sudo. This is expected and safe:

```text
apt-get check skipped: collector does not invoke sudo
```

## Development

Run syntax checks:

```bash
bash -n wsl2-info-lib.sh ubuntu-health.sh wsl2-shell.sh wsl2-powershell.sh wsl2-info.sh collect-status.sh
```

Run a short smoke test:

```bash
rm -rf /tmp/wsl2-info-smoke
./wsl2-info.sh --brief --timeout 5 --output-dir /tmp/wsl2-info-smoke
```

Run optional branch smoke tests:

```bash
./wsl2-info.sh --full --timeout 10 --output-dir /tmp/wsl2-info-full-smoke
./wsl2-info.sh --brief --network --ollama --timeout 10 --output-dir /tmp/wsl2-info-options-smoke
./wsl2-info.sh --network --timeout 10 --output-dir /tmp/wsl2-info-network-smoke
./wsl2-info.sh --ollama --timeout 10 --output-dir /tmp/wsl2-info-ollama-smoke
./wsl2-info.sh --all --timeout 10 --output-dir /tmp/wsl2-info-all-smoke
```
