# On Windows

The daemon runs on Windows, and the sandbox runs in WSL2. This page says what
that combination means, what changes in the enforcement story, and how to set
each part up. The measurements behind it live in
[`research/`](https://github.com/talaria0101/malaria/tree/main/research) and
[`experiments/`](https://github.com/talaria0101/malaria/tree/main/experiments);
where something here says "measured", the battery that measured it is named.

## What runs where

On Linux, errand drives podman directly and both live on one machine. On
Windows there is an extra hop, and everything about the port follows from it:

- the daemon runs on Windows, as `errand.exe`, started by Task Scheduler or
  by hand;
- the `podman` it finds on PATH is a client, which relays to a podman
  machine;
- the machine is a WSL2 distro, running a custom Fedora image, and it is
  where the containers actually run, rootless, as the machine's own user.

So every flag errand passes is interpreted inside the machine by the podman
and pasta that live there. The Windows side chooses where the machine looks,
and moves bytes.

## The two arrangements

**Daemon on Windows** is the arrangement this page describes: one program
installed on the machine you use, containers in WSL2 below it. Project roots
on `C:\` work, and the volume is served through the WSL drive mount, which
works but is slower than the machine's own filesystem and does not deliver
inotify events or enforce permission bits. Tools inside the session that rely
on either (watch modes, some test runners) misbehave in ways no container
flag can fix.

**Daemon inside WSL** closes the gap by moving the daemon into the same
kernel the containers use. A project root in the distro's own filesystem then
behaves like it does on Linux, and the only Windows involvement is the
terminal you look at. If you already live in WSL, this arrangement is simpler
and faster; the rest of this page is about the other one, because it is the
one with surprises.

## What the sandbox can promise on this stack

The daemon probes the backend at startup and reports what it can enforce on
this host, and on Windows that report says more, because two things are
different.

**The isolated network closes the machine, not Windows.** The flags errand
passes (`pasta:--map-host-loopback,none,--map-guest-addr,none`) stop pasta
from mapping any host address into the container, which on a Linux host
closes the path to services bound on the host. In the machine context the
"host" pasta protects is the machine itself. The Windows host is one route
beyond it, across the WSL NAT, and what crosses that NAT is decided by the
Hyper-V firewall for WSL, which is a policy of the Windows host and invisible
from here. The daemon reports this as a gap rather than guessing at your
firewall: with `sandbox.network` set to `none` the question disappears, and
otherwise it is yours to close and to verify. To see which way your machine
falls, run a listener on Windows and try it from a container on the machine's
network; the battery in `experiments/windows/battery.ps1` is exactly that,
and its run on a stock Windows Server 2025 runner measured this way:

- with the errand flags: internet and DNS reachable, the machine's mapped
  address (169.254.1.2) unreachable, the Windows host (the WSL NAT gateway)
  unreachable, `host.containers.internal` unreachable;
- with podman's default pasta: internet and DNS reachable, the mapped
  address answering (connection refused, which is the mapping alive), the
  Windows host still unreachable behind the firewall's default.

So on a stock host the Windows hop starts closed and the flags do exactly
what they do on Linux, one hop nearer. The gap stays in the report because
the firewall is yours: a `Set-NetFirewallHyperVVMSetting` change reopens the
path and the daemon has no way to see that from inside.

**Volumes are not relabelled.** On Linux, errand mounts the project and the
state directory with `:Z`, which relabels them for SELinux and keeps a shared
volume from becoming a hole. The podman machine has no SELinux to relabel
with, so on Windows the suffix is plain `rw`, which the client accepted
without complaint. Nothing else about the mounts changes: `--read-only`, the
tmpfs at `/tmp`, and `--userns=keep-id` are passed and hold as on Linux, and
keep-id mapped to the machine's own user, uid 1000, as expected. Files the
daemon writes into the mount arrive executable inside the container, because
the drive mount maps them 0777; the daemon's `chmod 0755` is a formality
there. A fixed write measured about eleven times slower through the drive
mount than on the machine's own filesystem (69 MB/s against 767 MB/s), which
is the number behind the advice above.

Everything else in [sandboxing](/sandboxing) reads the same on Windows: one
container per session, capability dropped set, no new privileges, memory,
cpu, process, and single-file limits, and a state directory the agent can
write and nothing else. Measured on the same run: a container started with
`--cap-drop=ALL` reports zero effective capabilities, `--read-only` refuses
writes to the root filesystem while the tmpfs at `/tmp` stays writable,
`--memory`, `--cpus`, and `--pids-limit` arrive in the container's own cgroup
(512m, 1.5 cores, 64 processes in the probe), and a container killed by its
memory limit relays exit code 137 to the daemon, so the resource-limit
diagnosis reads the same as on Linux. The RPC channel between the daemon and
the agent is lines on stdin and stdout, and a line piped through the Windows
client into a container and back came out intact.

## Configuration

The search order on Windows is the same idea with Windows spellings:

1. `%APPDATA%\errand\config.json`
2. `%USERPROFILE%\.config\errand\config.json`
3. `%ProgramData%\errand\config.json`
4. `config.json` in the working directory

`ERRAND_CONFIG` names one outright and skips the search, exactly as
elsewhere. A token is in the file, so keep it readable by you alone:

```powershell
icacls "$env:APPDATA\errand" /inheritance:r /grant:r "$env:USERNAME:(F)"
```

## Building and running

The Linux build of the repository cross-compiles the Windows binary, so a
Windows host needs neither a checkout nor a toolchain:

```sh
deno task build
deno compile --target x86_64-pc-windows-msvc --allow-net --allow-env --allow-read --allow-write --allow-run --output dist/errand.exe src/main.ts
```

Before installing it as a service, check the host:

```powershell
.\errand.exe doctor
```

`doctor` runs the same probe the daemon runs at startup: it names the backend
it found, prints what it can enforce here, and refuses with the reason when
it cannot run at all. On Windows the report names the machine context and, on
a networked sandbox, states the Hyper-V firewall gap described above.

## As a service

A scheduled task at logon is the Windows spelling of the service definitions
in `packaging/`:

```powershell
schtasks /Create /TN "errand" /SC ONLOGON /RL LIMITED /TR "C:\errand\errand.exe run"
```

The daemon runs as you, not as an administrator, for the same reason the
systemd and OpenRC definitions run as an ordinary account: the configuration
file holds the bot token, and files an agent writes in a project should
belong to the person whose project it is.

## bailey on Windows, and inside WSL

bailey confines sessions as host processes with Landlock, seccomp, and
namespaces. It is a Linux tool and stays one: on a Windows host the probe
refuses it with the reason, and there is nothing to fix, because the backend
that works there is podman.

Inside WSL it is a different question, and the honest answer is that it
depends on the kernel in ways the daemon refuses to guess about. Microsoft's
kernel branches all ship Landlock and list it in the LSM set, so the
filesystem policy should apply; the machine the battery booted runs kernel
6.18, and its LSM list said `capability,landlock,yama,safesetid,selinux`.
But the same kernel answered a Landlock version query with EINVAL and
published no landlock directory under securityfs, so whether Landlock is
usable there is not settled by reading the config or the list. This is why
the daemon does not take bailey's word for any of it: bailey's own probe
attempts the real setup in a throwaway child, and errand refuses to start on
anything the probe cannot prove. What the port adds is the one check the
tool's report cannot self-certify: network rules need Landlock ABI 4
(Linux 6.7), the tool negotiates down instead of failing, and a networked
session on a kernel below that now refuses to start rather than run with its
egress policy silently skipped.

Per-session memory, cpu, and process limits inside WSL want `systemd=true`
in `/etc/wsl.conf`, so there is a cgroup subtree to delegate; without it the
daemon reports the same gap it reports on any Linux host without delegation.
One more shape-B caveat is measured: Ubuntu 24.04's pasta predates
`--map-host-loopback`, so the restricted-network flags refuse to start there;
use a distro whose pasta is new enough, which the podman machine's own Fedora
image is.

## The binfmt question, measured

WSL's Windows interop is a binfmt_misc handler: the kernel routes PE
executables to /init, which launches them on the Windows side. The handler
is registered kernel-wide, so a container's exec of a Windows binary reaches
it. Measured: the exec failed inside the container (exit 1, no Windows
process, the container's shell carried on), with the handler complaining on
its way out. The path is reachable but fails closed.

## What was measured, and where

- the kernel facts above were read from Microsoft's own configs for the
  5.15, 6.1, 6.6, and 6.18 branches: `research/wsl-kernel.md`;
- the machine architecture and pasta flag semantics come from podman's and
  passt's own documentation, re-derived for the machine context in
  `research/podman-machine.md`;
- the runtime choice (Deno, and why not Bun) is `research/runtimes.md`, with
  the refusal-by-default experiment run on both runtimes;
- what a real podman machine on WSL2 does with all of it is the battery in
  `experiments/windows/battery.ps1`, run on a GitHub windows-latest runner
  with podman 6.1.1 and a machine on kernel 6.18, and its recorded output is
  committed under `experiments/results/`;
- the daemon's own suite runs green on both Linux and Windows runners, and
  the Windows binary is built on every push.

How the reviews of this port were run, and what each one found, is in
`docs/reviews.md`.
