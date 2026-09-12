# The podman-on-WSL experiment battery.
#
# Installs podman, brings up its machine with the WSL2 provider, and measures
# everything the errand port depends on: what the restricted-network flags
# close on this stack, what the volume spellings do, what keep-id maps to,
# whether limits are applied, and how exit codes and filesystems behave.
# Each experiment writes JSON into experiments/results/.

$ErrorActionPreference = "Continue"
$results = "experiments/results"
New-Item -ItemType Directory -Force -Path $results | Out-Null
$summary = New-Object System.Collections.Generic.List[string]
Start-Transcript -Path "$results\transcript.log" -Append | Out-Null

function Stamp([string]$message) {
  Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $message)
}

function Record([string]$name, $data) {
  $json = $data | ConvertTo-Json -Depth 6
  Set-Content -Path "$results/$name.json" -Value $json
  $summary.Add("## $name`n`n``````json`n$json`n``````") | Out-Null
  Write-Host "=== $name ==="
  Write-Host $json
}

function Run([string]$label, [scriptblock]$block) {
  Write-Host "--- $label"
  try {
    return & $block
  } catch {
    Write-Host "threw: $_"
    return $null
  }
}

function PodmanOutput([string[]]$arguments, [int]$timeoutSeconds = 180) {
  Stamp ("podman " + ($arguments -join ' '))
  $task = Run "podman $($arguments -join ' ')" {
    $p = Start-Process -FilePath "podman" -ArgumentList $arguments `
      -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput "$env:TEMP\podman-out.txt" `
      -RedirectStandardError "$env:TEMP\podman-err.txt"
    return @{
      code = $p.ExitCode
      stdout = (Get-Content "$env:TEMP\podman-out.txt" -Raw -ErrorAction SilentlyContinue)
      stderr = (Get-Content "$env:TEMP\podman-err.txt" -Raw -ErrorAction SilentlyContinue)
    }
  }
  return $task
}

# ---- 0. environment -------------------------------------------------------

$env0 = Run "environment" {
  @{
    windowsVersion = [System.Environment]::OSVersion.VersionString
    wslVersion = (wsl --version | Out-String).Trim()
    wslStatus = (wsl --status | Out-String).Trim()
    distros = (wsl --list --verbose | Out-String).Trim()
  }
}
if ($env0) { Record "00-environment" $env0 }

# ---- 1. install podman ----------------------------------------------------

$installed = Run "install podman" {
  $existing = Get-Command podman -ErrorAction SilentlyContinue
  if ($existing) { return "already present: $($existing.Source)" }
  # choco first: winget has been observed to hang on Server SKUs.
  choco install podman-cli -y --no-progress 2>&1 | Out-Host
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("Path", "User")
  $found = Get-Command podman -ErrorAction SilentlyContinue
  if ($found) { return $found.Source }
  foreach ($candidate in @(
    "C:\Program Files\Podman\podman.exe",
    "$env:ProgramFiles\Podman\podman.exe",
    "C:\ProgramData\chocolatey\bin\podman.exe",
    "C:\ProgramData\chocolatey\lib\podman-cli\tools\podman.exe"
  )) {
    if (Test-Path $candidate) { return $candidate }
  }
  throw "podman not found after install"
}
Write-Host "podman: $installed"

# ---- 2. machine init and start --------------------------------------------

Run "wsl default version" {
  wsl --set-default-version 2 2>&1 | Out-Host
}

$init = PodmanOutput @("machine", "init") 600
Record "01-machine-init" @{ result = $init }

$start = PodmanOutput @("machine", "start") 600
Record "02-machine-start" @{ tail = if ($start.stderr) { $start.stderr.Substring(0, [Math]::Min(2000, $start.stderr.Length)) } else { $start.stdout } }

$info = PodmanOutput @("info", "--format", "{{json .}}")
$infoJson = $null
try { $infoJson = $info.stdout | ConvertFrom-Json } catch {}
Record "03-info-rootless" @{
  rootlessQuery = $info.stderr
  rootless = if ($infoJson) { $infoJson.Host.Security.Rootless } else { $null }
  podmanVersion = if ($infoJson) { $infoJson.Version.Version } else { $null }
  hostArch = if ($infoJson) { $infoJson.Host.Arch } else { $null }
  cgroupManager = if ($infoJson) { $infoJson.Host.CgroupManager } else { $null }
  networkBackend = if ($infoJson) { $infoJson.Host.NetworkBackend } else { $null }
}

# ---- 3. candidate host addresses ------------------------------------------

# A listener on the Windows host, then every address a container might use to
# reach it: the WSL NAT gateway, the WSL vNIC, the runner's own address, and
# the names podman promises to map.

function Ssh([string]$command, [int]$timeoutSeconds = 120) {
  Stamp ("podman machine ssh: " + $command)
  $out = "$env:TEMP\ssh-out.txt"
  $err = "$env:TEMP\ssh-err.txt"
  Remove-Item $out, $err -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath "podman" -ArgumentList "machine", "ssh", $command `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $out `
    -RedirectStandardError $err
  if (-not $p.WaitForExit($timeoutSeconds * 1000)) {
    try { $p.Kill() } catch {}
    return "TIMED OUT after ${timeoutSeconds}s"
  }
  return ((Get-Content $out -Raw -ErrorAction SilentlyContinue) +
          (Get-Content $err -Raw -ErrorAction SilentlyContinue))
}

$listener = Run "host listener" {
  Set-Content -Path "$env:TEMP\listener-root.txt" -Value "errand-probe-listener"
  $p = Start-Process -FilePath "python" `
    -ArgumentList "-m", "http.server", "8999", "--bind", "0.0.0.0", "--directory", "$env:TEMP" `
    -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 2
  return $p.Id
}
Write-Host "listener pid: $listener"

$addresses = Run "candidate addresses" {
  $wslAdapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like "*WSL*" -or $_.InterfaceAlias -like "*vEthernet*" } |
    ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" }
  $primary = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } |
    ForEach-Object { $_.IPv4Address.IPAddress })
  $machineGateway = (Ssh "ip route show default")
  $machineAddresses = (Ssh "ip -4 addr show eth0")
  return @{
    wslAdapters = $wslAdapters
    primary = $primary
    machineDefaultRoute = $machineGateway
    machineEth0 = $machineAddresses
  }
}
Record "04-host-addresses" $addresses

$machineGatewayIp = $null
if ($addresses.machineDefaultRoute -match "default via ([0-9.]+)") {
  $machineGatewayIp = $Matches[1]
}

# ---- 4. reachability battery ----------------------------------------------

# Each target is probed under the errand restricted network and under the
# default network, so the difference is the measurement.

$restricted = "pasta:--map-host-loopback,none,--map-guest-addr,none"

function ProbeFromContainer([string]$networkArgs, [string]$label) {
  $targets = @()
  if ($machineGatewayIp) { $targets += $machineGatewayIp }
  $targets += @("169.254.1.2", "host.containers.internal")
  $entries = @()
  foreach ($target in ($targets | Select-Object -Unique)) {
    $out = PodmanOutput @("run", "--rm", $networkArgs, "alpine:3", `
      "wget", "-q", "-T", "5", "-O", "-", "http://${target}:8999/listener-root.txt")
    $entries += @{
      target = $target
      code = $out.code
      reached = ($out.code -eq 0 -and $out.stdout -match "errand-probe-listener")
      note = if ($out.code -ne 0) { ($out.stderr -split "`n" | Select-Object -Last 2) -join " | " } else { "" }
    }
  }
  $dns = PodmanOutput @("run", "--rm", $networkArgs, "alpine:3", `
    "nslookup", "api.github.com")
  $internet = PodmanOutput @("run", "--rm", $networkArgs, "alpine:3", `
    "wget", "-q", "-T", "10", "-O", "-", "https://api.github.com/zen")
  return @{
    label = $label
    targets = $entries
    dns = @{ code = $dns.code; note = if ($dns.code -ne 0) { $dns.stderr } else { "resolved" } }
    internet = @{ code = $internet.code; body = if ($internet.stdout) { $internet.stdout.Trim() } else { ($internet.stderr -split "`n" | Select-Object -Last 1) } }
  }
}

Record "05-restricted-network" (ProbeFromContainer "--network=$restricted" "restricted (errand flags)")
Record "06-default-network" (ProbeFromContainer "--network=pasta" "podman default pasta")

# ---- 5. filesystem and identity -------------------------------------------

$mountRoot = "C:\errand-probe-mount"
Remove-Item -Recurse -Force $mountRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $mountRoot | Out-Null

$volumeSpellings = @()
foreach ($spelling in @("${mountRoot}:/workspace", "${mountRoot -replace '\\','/'}:/workspace")) {
  $out = PodmanOutput @("run", "--rm", "-v", $spelling, "alpine:3", `
    "sh", "-c", "echo probe > /workspace/probe.txt")
  $volumeSpellings += @{
    spelling = $spelling
    code = $out.code
    note = if ($out.code -ne 0) { ($out.stderr -split "`n" | Select-Object -Last 1) } else { "accepted" }
  }
}
Record "07-volume-spellings" @{ spellings = $volumeSpellings }

$fs = PodmanOutput @("run", "--rm", "--userns=keep-id", "-v", "${mountRoot}:/workspace", "alpine:3", `
  "sh", "-c",
  "id; echo probe > /workspace/from-container.txt; chmod +x /workspace/script.sh; ls -l /workspace/script.sh; /workspace/script.sh; cat /proc/self/status | grep CapEff")
Set-Content -Path "$mountRoot\script.sh" -Value "#!/bin/sh`necho executed-ok"
Record "08-keep-id-and-drvfs" @{
  code = $fs.code
  stdout = $fs.stdout
  stderr = if ($fs.code -ne 0) { $fs.stderr } else { "" }
}

$selinux = PodmanOutput @("run", "--rm", "-v", "${mountRoot}:/workspace:rw,Z", "alpine:3", `
  "touch", "/workspace/from-z-label.txt")
Record "09-z-label" @{
  code = $selinux.code
  stderr = if ($selinux.code -ne 0) { $selinux.stderr } else { "(accepted)" }
}

$readonly = PodmanOutput @("run", "--rm", "--read-only", "--tmpfs", "/tmp", "alpine:3", `
  "sh", "-c", "touch /root-readonly-test 2>&1; touch /tmp/tmpfs-test && echo tmpfs-ok")
Record "10-readonly-tmpfs" @{
  code = $readonly.code
  stdout = $readonly.stdout
}

# ---- 6. limits -------------------------------------------------------------

$limits = PodmanOutput @("run", "--rm", "--memory", "512m", "--cpus", "1.5", `
  "--pids-limit", "64", "alpine:3", `
  "sh", "-c", "cat /sys/fs/cgroup/memory.max; cat /sys/fs/cgroup/cpu.max; cat /sys/fs/cgroup/pids.max")
Record "11-limits-in-container" @{
  code = $limits.code
  stdout = $limits.stdout
  stderr = if ($limits.code -ne 0) { $limits.stderr } else { "" }
}

# ---- 7. exit codes ---------------------------------------------------------

$exit137 = PodmanOutput @("run", "--rm", "alpine:3", "sh", "-c", "kill -9 `"`$`$`"")
$exit42 = PodmanOutput @("run", "--rm", "alpine:3", "sh", "-c", "exit 42")
Record "12-exit-codes" @{
  sigkill = @{ code = $exit137.code; stderr = if ($exit137.code -ne 0) { $exit137.stderr } else { "" } }
  explicit = @{ code = $exit42.code }
}

# ---- 8. kernel surface inside the machine -----------------------------------

$kernel = Ssh "uname -r; cat /sys/kernel/security/lsm 2>/dev/null; cat /sys/kernel/security/landlock/abi 2>/dev/null; stat -fc %T /sys/fs/cgroup; cat /proc/sys/user/max_user_namespaces; ls /init 2>&1 | head -1; ls /proc/sys/fs/binfmt_misc/ 2>/dev/null"
Record "13-machine-kernel" @{
  stdout = $kernel.stdout
  stderr = $kernel.stderr
}

# ---- 9. the /init interop question ------------------------------------------

# WSL interop registers a binfmt_misc handler that routes Windows executables
# to /init. Whether a container can reach any of that decides one containment
# question without involving errand at all.

$interop = PodmanOutput @("run", "--rm", "alpine:3", `
  "sh", "-c",
  "printf 'MZ' > /tmp/fake.exe; chmod +x /tmp/fake.exe; /tmp/fake.exe 2>&1; echo exec-code=`$?; ls /proc/sys/fs/binfmt_misc/ 2>&1")
Record "14-interop-from-container" @{
  code = $interop.code
  stdout = $interop.stdout
  stderr = $interop.stderr
}

# ---- 10. DrvFS performance ---------------------------------------------------

$perf = Run "drvfs performance" {
  Ssh "dd if=/dev/zero of=/tmp/ddtest bs=1M count=128 2>&1 | tail -1; rm /tmp/ddtest" | Out-Host
  $ext4 = Ssh "time dd if=/dev/zero of=/tmp/ddtest bs=1M count=128 2>&1 | tail -1"
  Ssh "rm -f /tmp/ddtest" | Out-Host
  return @{
    ext4Write = $ext4
    drvfsNote = "write the same file through a container mount in 15-drvfs-write"
  }
}
Record "15-machine-fs-perf" $perf

$drvfsWrite = PodmanOutput @("run", "--rm", "-v", "${mountRoot}:/workspace", "alpine:3", `
  "dd", "if=/dev/zero", "of=/workspace/ddtest", "bs=1M", "count=128")
$drvfsSeconds = $null
if ($drvfsWrite.stderr -match "([\d.]+) [mk]?s?B/s|([\d,.]+) MB/s") { }
if ($drvfsWrite.stderr -match "copied, ([\d.]+) s") { $drvfsSeconds = $Matches[1] }
Record "16-drvfs-write" @{
  code = $drvfsWrite.code
  stderrTail = if ($drvfsWrite.stderr) { ($drvfsWrite.stderr -split "`n" | Select-Object -Last 2) -join " | " } else { "" }
  seconds = $drvfsSeconds
}

# ---- cleanup ----------------------------------------------------------------

if ($listener) { Stop-Process -Id $listener -Force -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $mountRoot -ErrorAction SilentlyContinue
$stop = PodmanOutput @("machine", "stop")
Write-Host "machine stop: $($stop.code)"
Stop-Transcript | Out-Null

$summary.Add("## environment notes") | Out-Null
Set-Content -Path "$results\SUMMARY.md" -Value ($summary -join "`n`n")
Write-Host "battery complete"
