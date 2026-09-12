# Shape B: the daemon and podman both inside a WSL distro.
#
# The other shape runs the daemon on Windows and podman in its machine. This
# one measures the alternative: podman installed natively in a WSL distro,
# rootless, with the same restricted-network flags. What differs is which
# hop counts as "the host": here it is the WSL distro, and the Windows host is
# still one gateway beyond it.

$ErrorActionPreference = "Continue"
$results = "experiments/results"
New-Item -ItemType Directory -Force -Path $results | Out-Null

function Record([string]$name, $data) {
  $json = $data | ConvertTo-Json -Depth 6
  Set-Content -Path "$results/$name.json" -Value $json
  Write-Host "=== $name ==="
  Write-Host $json
}

function Wsl([string[]]$arguments) {
  $out = wsl.exe @arguments 2>&1
  return ($out | Out-String)
}

# ---- install a distro -------------------------------------------------------

Write-Host "installing Ubuntu-24.04"
$install = Wsl @("--install", "-d", "Ubuntu-24.04", "--no-launch", "--web-download")
Record "b0-distro-install" @{ output = $install.Trim() }

# ---- podman inside the distro ----------------------------------------------

$setup = Wsl @("-d", "Ubuntu-24.04", "-u", "root", "--",
  "/bin/bash", "-lc",
  "apt-get update -qq && apt-get install -y -qq podman >/dev/null 2>&1; podman --version; id")
Record "b1-distro-podman" @{ output = $setup.Trim() }

# ---- kernel surface (same kernel as the machine, read from a distro) --------

$kernel = Wsl @("-d", "Ubuntu-24.04", "--",
  "/bin/bash", "-lc",
  "uname -r; cat /sys/kernel/security/lsm 2>/dev/null; cat /sys/kernel/security/landlock/abi 2>/dev/null; stat -fc %T /sys/fs/cgroup; cat /proc/sys/user/max_user_namespaces; systemctl --version 2>/dev/null | head -1 || echo no-systemd")
Record "b2-distro-kernel" @{ output = $kernel.Trim() }

# ---- host addresses from the distro's point of view -------------------------

$route = Wsl @("-d", "Ubuntu-24.04", "--", "/bin/bash", "-lc", "ip route show default")
Record "b3-distro-route" @{ output = $route.Trim() }
$gateway = $null
if ($route -match "default via ([0-9.]+)") { $gateway = $Matches[1] }

# ---- listener on the Windows host -------------------------------------------

Set-Content -Path "$env:TEMP\listener-root.txt" -Value "errand-probe-listener"
$listener = Start-Process -FilePath "python" `
  -ArgumentList "-m", "http.server", "8998", "--bind", "0.0.0.0", "--directory", "$env:TEMP" `
  -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2

# ---- reachability: restricted flags, native rootless in the distro -----------

$restricted = "pasta:--map-host-loopback,none,--map-guest-addr,none"
$targets = @($gateway, "169.254.1.2", "10.255.255.250") | Where-Object { $_ }
$entries = @()
foreach ($target in ($targets | Select-Object -Unique)) {
  $out = Wsl @("-d", "Ubuntu-24.04", "--", "/bin/bash", "-lc",
    "podman run --rm --network=$restricted alpine:3 wget -q -T 5 -O - http://${target}:8998/listener-root.txt 2>&1; echo code=`$?")
  $entries += @{
    target = $target
    output = $out.Trim()
  }
}

$internet = Wsl @("-d", "Ubuntu-24.04", "--", "/bin/bash", "-lc",
  "podman run --rm --network=$restricted alpine:3 wget -q -T 10 -O - https://api.github.com/zen 2>&1; echo code=`$?")
$uid = Wsl @("-d", "Ubuntu-24.04", "--", "/bin/bash", "-lc",
  "podman run --rm --userns=keep-id alpine:3 id")

Record "b4-shape-b-reachability" @{
  targets = $entries
  internet = $internet.Trim()
  keepId = $uid.Trim()
}

Stop-Process -Id $listener -Force -ErrorAction SilentlyContinue
Write-Host "shape B battery complete"
