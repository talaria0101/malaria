# The podman-on-WSL experiment battery.
#
# Installs podman, brings up its machine with the WSL2 provider, and measures
# everything the errand port depends on. Every podman call is capped, machine
# start streams its output so a stall is visible in the log, and if the
# Windows-side machine cannot be driven, the same container battery runs
# through wsl.exe directly into the machine distro.

$ErrorActionPreference = "Continue"
$results = "experiments/results"
New-Item -ItemType Directory -Force -Path $results | Out-Null
Start-Transcript -Path "$results\transcript.log" -Append | Out-Null

function Stamp([string]$message) {
  Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $message)
}

function Record([string]$name, $data) {
  $json = $data | ConvertTo-Json -Depth 6
  Set-Content -Path "$results/$name.json" -Value $json
  Stamp $name
  Write-Host $json
}

function Run([string]$label, [scriptblock]$block) {
  Stamp $label
  try {
    return & $block
  } catch {
    Write-Host "threw: $_"
    return $null
  }
}

# PodmanOutput runs a podman command with a hard cap and returns what it said.
# With -ThroughWsl the same command is driven through wsl.exe into the machine
# distro, which measures the containers even when the Windows-side API
# forwarding is what is broken.
$script:ThroughWsl = $false

function PodmanOutput([string[]]$arguments, [int]$timeoutSeconds = 180) {
  Stamp ("podman" + ($(if ($script:ThroughWsl) { " (via wsl) " } else { " " })) + ($arguments -join ' '))
  $out = "$env:TEMP\podman-out.txt"
  $err = "$env:TEMP\podman-err.txt"
  Remove-Item $out, $err -ErrorAction SilentlyContinue
  if ($script:ThroughWsl) {
    $wslArgs = @("-d", "podman-machine-default", "-u", "user", "--", "podman") + $arguments
    $p = Start-Process -FilePath "wsl.exe" -ArgumentList $wslArgs `
      -NoNewWindow -PassThru `
      -RedirectStandardOutput $out `
      -RedirectStandardError $err
  } else {
    $p = Start-Process -FilePath "podman" -ArgumentList $arguments `
      -NoNewWindow -PassThru `
      -RedirectStandardOutput $out `
      -RedirectStandardError $err
  }
  if (-not $p.WaitForExit($timeoutSeconds * 1000)) {
    try { $p.Kill() } catch {}
    return @{ code = -1; stdout = ""; stderr = "TIMED OUT after ${timeoutSeconds}s" }
  }
  return @{
    code = $p.ExitCode
    stdout = (Get-Content $out -Raw -ErrorAction SilentlyContinue)
    stderr = (Get-Content $err -Raw -ErrorAction SilentlyContinue)
  }
}

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

# ---- 0. environment -------------------------------------------------------

$env0 = Run "environment" {
  @{
    windowsVersion = [System.Environment]::OSVersion.VersionString
    wslVersion = (wsl --version | Out-String).Trim()
    distros = ((wsl --list --verbose | Out-String) -replace "\x00", "").Trim()
  }
}
if ($env0) { Record "00-environment" $env0 }

# ---- 1. install podman ----------------------------------------------------

$installed = Run "install podman" {
  $existing = Get-Command podman -ErrorAction SilentlyContinue
  if ($existing) { return "already present: $($existing.Source)" }
  Stamp "choco install podman-cli"
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
$podmanDir = Split-Path $installed -Parent
$env:Path += ";$podmanDir"

# ---- 2. machine init and start --------------------------------------------

Run "wsl default version" {
  Stamp "wsl --set-default-version 2"
  $p = Start-Process -FilePath "wsl" -ArgumentList "--set-default-version", "2" `
    -NoNewWindow -PassThru -Wait `
    -RedirectStandardOutput "$env:TEMP\wsl-out.txt" `
    -RedirectStandardError "$env:TEMP\wsl-err.txt"
  Get-Content "$env:TEMP\wsl-out.txt", "$env:TEMP\wsl-err.txt" -ErrorAction SilentlyContinue |
    ForEach-Object { $_ -replace "\x00", "" } | Out-Host
}

$init = PodmanOutput @("machine", "init") 600
Record "01-machine-init" @{ result = $init }

# machine start streams, so a stall is visible in the log where it happens.
Stamp "podman machine start (streamed)"
$started = Run "machine start" {
  $p = Start-Process -FilePath "podman" -ArgumentList "machine", "start" `
    -NoNewWindow -PassThru
  if (-not $p.WaitForExit(600 * 1000)) {
    try { $p.Kill() } catch {}
    return @{ code = -1; note = "TIMED OUT after 600s" }
  }
  return @{ code = $p.ExitCode; note = "exited" }
}
Record "02-machine-start" $started

# If the Windows client cannot reach the machine, drive the containers
# through wsl.exe into the machine distro instead.
$info = PodmanOutput @("info", "--format", "{{.Host.Security.Rootless}}") 120
if ($info.code -ne 0 -or $info.stdout.Trim() -ne "true") {
  Stamp "windows client cannot reach the machine; switching to wsl-driven podman"
  $script:ThroughWsl = $true
  $info = PodmanOutput @("info", "--format", "{{.Host.Security.Rootless}}") 120
}
$infoJson = PodmanOutput @("info", "--format", "{{json .}}") 120
$infoParsed = $null
try { $infoParsed = $infoJson.stdout | ConvertFrom-Json } catch {}
Record "03-info-rootless" @{
  throughWsl = $script:ThroughWsl
  rootless = $info.stdout.Trim()
  podmanVersion = if ($infoParsed) { $infoParsed.Version.Version } else { $null }
  hostArch = if ($infoParsed) { $infoParsed.Host.Arch } else { $null }
  cgroupManager = if ($infoParsed) { $infoParsed.Host.CgroupManager } else { $null }
  networkBackend = if ($infoParsed) { $infoParsed.Host.NetworkBackend } else { $null }
}

# ---- 3. candidate host addresses ------------------------------------------

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
  $hyperVFirewall = (Get-NetFirewallHyperVVMSetting -ErrorAction SilentlyContinue |
    Select-Object Name, DefaultInboundAction, LoopbackEnabled | Out-String)
  return @{
    wslAdapters = $wslAdapters
    primary = $primary
    machineDefaultRoute = $machineGateway
    machineEth0 = $machineAddresses
    hyperVFirewall = $hyperVFirewall
  }
}
Record "04-host-addresses" $addresses

$machineGatewayIp = $null
if ($addresses.machineDefaultRoute -match "default via ([0-9.]+)") {
  $machineGatewayIp = $Matches[1]
}

# ---- 4. reachability battery ----------------------------------------------

$restricted = "pasta:--map-host-loopback,none,--map-guest-addr,none"

function ProbeFromContainer([string]$networkArgs, [string]$label) {
  $targets = @()
  if ($machineGatewayIp) { $targets += $machineGatewayIp }
  $targets += @("169.254.1.2", "host.containers.internal")
  $entries = @()
  foreach ($target in ($targets | Select-Object -Unique)) {
    $out = PodmanOutput @("run", "--rm", $networkArgs, "alpine:3", `
      "wget", "-q", "-T", "5", "-O", "-", "http://${target}:8999/listener-root.txt") 120
    $entries += @{
      target = $target
      code = $out.code
      reached = ($out.code -eq 0 -and $out.stdout -match "errand-probe-listener")
      note = if ($out.code -ne 0) { ($out.stderr -split "`n" | Select-Object -Last 2) -join " | " } else { "" }
    }
  }
  $dns = PodmanOutput @("run", "--rm", $networkArgs, "alpine:3", `
    "nslookup", "api.github.com") 120
  $internet = PodmanOutput @("run", "--rm", $networkArgs, "alpine:3", `
    "wget", "-q", "-T", "10", "-O", "-", "https://api.github.com/zen") 180
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
    "sh", "-c", "echo probe > /workspace/probe.txt") 120
  $volumeSpellings += @{
    spelling = $spelling
    code = $out.code
    note = if ($out.code -ne 0) { ($out.stderr -split "`n" | Select-Object -Last 1) } else { "accepted" }
  }
}
Record "07-volume-spellings" @{ spellings = $volumeSpellings }

Set-Content -Path "$mountRoot\script.sh" -Value "#!/bin/sh`necho executed-ok"
Set-Content -Path "$mountRoot\probe.sh" -Value @'
id
echo probe > /workspace/from-container.txt
ls -l /workspace/script.sh
/workspace/script.sh
grep CapEff /proc/self/status
'@
$fs = PodmanOutput @("run", "--rm", "--userns=keep-id", "-v", "${mountRoot}:/workspace", "alpine:3", `
  "sh", "/workspace/probe.sh") 120
Record "08-keep-id-and-drvfs" @{
  code = $fs.code
  stdout = $fs.stdout
  stderr = if ($fs.code -ne 0) { $fs.stderr } else { "" }
}

$selinux = PodmanOutput @("run", "--rm", "-v", "${mountRoot}:/workspace:rw,Z", "alpine:3", `
  "touch", "/workspace/from-z-label.txt") 120
Record "09-z-label" @{
  code = $selinux.code
  stderr = if ($selinux.code -ne 0) { $selinux.stderr } else { "(accepted)" }
}

Set-Content -Path "$mountRoot\readonly.sh" -Value @'
touch /root-readonly-test
echo rootfs-code=$?
touch /tmp/tmpfs-test && echo tmpfs-ok
'@
$readonly = PodmanOutput @("run", "--rm", "--read-only", "--tmpfs", "/tmp", `
  "-v", "${mountRoot}:/workspace", "alpine:3", "sh", "/workspace/readonly.sh") 120
Record "10-readonly-tmpfs" @{
  code = $readonly.code
  stdout = $readonly.stdout
}

# ---- 6. limits -------------------------------------------------------------

Set-Content -Path "$mountRoot\limits.sh" -Value @'
echo memory.max=$(cat /sys/fs/cgroup/memory.max)
echo cpu.max=$(cat /sys/fs/cgroup/cpu.max)
echo pids.max=$(cat /sys/fs/cgroup/pids.max)
'@
$limits = PodmanOutput @("run", "--rm", "--memory", "512m", "--cpus", "1.5", `
  "--pids-limit", "64", "-v", "${mountRoot}:/workspace", "alpine:3", "sh", "/workspace/limits.sh") 120
Record "11-limits-in-container" @{
  code = $limits.code
  stdout = $limits.stdout
  stderr = if ($limits.code -ne 0) { $limits.stderr } else { "" }
}

# ---- 7. exit codes ---------------------------------------------------------

Set-Content -Path "$mountRoot\sigkill.sh" -Value "kill -9 `$$`n"
$exit137 = PodmanOutput @("run", "--rm", "-v", "${mountRoot}:/workspace", "alpine:3", `
  "sh", "/workspace/sigkill.sh") 120
$exit42 = PodmanOutput @("run", "--rm", "alpine:3", "false") 120
$stdin = Run "stdin piping" {
  # The RPC channel is exactly this: lines in on stdin, lines back on stdout.
  $out = "piped-line" | & podman run --rm -i alpine:3 cat
  return @{ stdout = ($out | Out-String).Trim() }
}
Record "12-exit-codes-and-stdin" @{
  sigkill = @{ code = $exit137.code }
  false = @{ code = $exit42.code }
  stdinPiping = $stdin
}

# ---- 8. kernel surface inside the machine -----------------------------------

$kernel = Ssh "uname -r; sudo mount -t securityfs none /sys/kernel/security 2>&1; cat /sys/kernel/security/lsm 2>/dev/null; cat /sys/kernel/security/landlock/abi 2>/dev/null; stat -fc %T /sys/fs/cgroup; cat /proc/sys/user/max_user_namespaces; ls /init 2>&1 | head -1; ls /proc/sys/fs/binfmt_misc/ 2>/dev/null"
Record "13-machine-kernel" @{
  stdout = $kernel
}

# ---- 9. the /init interop question ------------------------------------------

Set-Content -Path "$mountRoot\interop.sh" -Value @'
echo MZ > /tmp/fake.exe
chmod +x /tmp/fake.exe
/tmp/fake.exe
echo exec-code=$?
ls /proc/sys/fs/binfmt_misc/
echo binfmt-done
'@
$interop = PodmanOutput @("run", "--rm", "-v", "${mountRoot}:/workspace", "alpine:3", `
  "sh", "/workspace/interop.sh") 120
Record "14-interop-from-container" @{
  code = $interop.code
  stdout = $interop.stdout
  stderr = $interop.stderr
}

# ---- 10. DrvFS write cost ---------------------------------------------------

$ext4 = Ssh "dd if=/dev/zero of=/tmp/ddtest bs=1M count=128 2>&1 | tail -1"
Ssh "rm -f /tmp/ddtest" | Out-Host
$drvfsWrite = PodmanOutput @("run", "--rm", "-v", "${mountRoot}:/workspace", "alpine:3", `
  "dd", "if=/dev/zero", "of=/workspace/ddtest", "bs=1M", "count=128") 300
Record "15-write-throughput" @{
  ext4InMachine = $ext4
  drvfsThroughMount = @{
    code = $drvfsWrite.code
    tail = if ($drvfsWrite.stderr) { ($drvfsWrite.stderr -split "`n" | Select-Object -Last 2) -join " | " } else { "" }
  }
}

# ---- cleanup ----------------------------------------------------------------

if ($listener) { Stop-Process -Id $listener -Force -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $mountRoot -ErrorAction SilentlyContinue
$stop = PodmanOutput @("machine", "stop") 300
Write-Host "machine stop: $($stop.code)"
Stop-Transcript | Out-Null
Write-Host "battery complete"
