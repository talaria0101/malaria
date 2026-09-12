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
network; the battery in `experiments/windows/battery.ps1` is exactly that.

**Volumes are not relabelled.** On Linux, errand mounts the project and the
state directory with `:Z`, which relabels them for SELinux and keeps a shared
volume from becoming a hole. The podman machine has no SELinux to relabel
with, so on Windows the suffix is plain `rw`. Nothing else about the mounts
changes: `--read-only`, the tmpfs at `/tmp`, and `--userns=keep-id` are
passed and hold as on Linux.

Everything else in [sandboxing](/sandboxing) reads the same on Windows: one
container per session, capability dropped set, no new privileges, memory,
cpu, process, and single-file limits, and a state directory the agent can
write and nothing else.

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

Inside WSL it is a different question. Microsoft's kernel has shipped
Landlock since the 5.15 branch and it is active in the LSM list, so the
filesystem policy applies. Network rules are the part with a version floor:
they need Landlock ABI 4, which is Linux 6.7, and WSL installs on older
branches (5.15, 6.1, 6.6) are below it. The tool negotiates down instead of
failing, so a session would run while its egress policy was silently
skipped; the daemon now reads the ABI out of the tool's report and refuses to
start a networked session on a kernel below 4, naming both the number it
found and the two ways out: a newer kernel (WSL2's current kernel is above
the floor), or `sandbox.network` set to `none`.

Per-session memory, cpu, and process limits inside WSL want `systemd=true`
in `/etc/wsl.conf`, so there is a cgroup subtree to delegate; without it the
daemon reports the same gap it reports on any Linux host without delegation.

## What was measured, and where

- the kernel facts above were read from Microsoft's own configs for the
  5.15, 6.1, 6.6, and 6.18 branches: `research/wsl-kernel.md`;
- the machine architecture and pasta flag semantics come from podman's and
  passt's own documentation, re-derived for the machine context in
  `research/podman-machine.md`;
- the runtime choice (Deno, and why not Bun) is `research/runtimes.md`, with
  the refusal-by-default experiment run on both runtimes;
- what a real podman machine on WSL2 does with all of it is the battery in
  `experiments/windows/battery.ps1`, and its recorded output is committed
  under `experiments/results/`.
