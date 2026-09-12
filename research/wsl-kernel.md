# The WSL2 kernel, read from its source tree

First person, measured by reading Microsoft's own kernel configuration for
each branch of microsoft/WSL2-Linux-Kernel, fetched on 2026-09-12 from
`Microsoft/config-wsl` on branches linux-msft-wsl-{5.15,6.1,6.6,6.18}.y.
Every distro inside WSL2 shares this one kernel, so these facts decide what
any confinement technique can do inside WSL regardless of distro.

## What is on

| Setting                         | 5.15 | 6.1 | 6.6 | 6.18 | Why errand cares                            |
| ------------------------------- | ---- | --- | --- | ---- | ------------------------------------------- |
| CONFIG_SECURITY_LANDLOCK        | y    | y   | y   | y    | bailey's filesystem policy                  |
| CONFIG_LSM includes landlock    | yes  | yes | yes | yes  | Landlock actually active, not just compiled |
| CONFIG_USER_NS                  | y    | y   | y   | y    | bailey's isolation layer, rootless podman   |
| CONFIG_SECCOMP / SECCOMP_FILTER | y    | y   | y   | y    | bailey's syscall denylist                   |
| CONFIG_MEMCG, CGROUP_SCHED      | y    | y   | y   | y    | per-session memory and cpu limits           |
| CONFIG_BINFMT_MISC              | y    | y   | y   | y    | the WSL interop handler lives here          |

So Landlock is not the blocker I expected it to be: it has been in Microsoft's
kernel since the 5.15 branch, and it is in the `lsm=` list, which is the part
distributions get wrong. What the kernel version does decide is the Landlock
ABI, and bailey's own docs (docs/reference/kernel.md in QaidVoid/bailey) say
what each ABI is worth:

- filesystem policy: ABI 1, so any WSL2 kernel from 5.13 on.
- network rules (egress by port): ABI 4, kernel 6.7. A WSL2 install on the
  6.6 branch or older accepts the policy and then does not enforce the
  network half of it.
- ABI 5 (ioctl, 6.10) and ABI 6 (abstract sockets and signals, 6.12): only
  the 6.18 branch has them.

The 5.15 branch has 4189 config lines and no `CONFIG_SECURITY_YAMA`; the 6.18
branch has 7402 and defaults to SELinux. Between those, 6.6 is the branch most
field installs are on, because it is what `wsl --update` shipped for a long
time.

## What this means for bailey inside WSL

bailey is a Linux tool; inside a WSL distro it runs like any other. The
filesystem half of its policy works on every kernel above. The network half
needs 6.7 or newer, and per-session memory, cpu, and process limits need a
cgroup v2 subtree delegated to the daemon, which in a WSL distro means
`systemd=true` in /etc/wsl.conf so systemd mounts the unified hierarchy and
can delegate a slice.

The errand daemon does not currently parse the ABI out of bailey's doctor
output: `parseDoctor` looks for `landlock:` saying yes or no and for
`cgroup delegation:`. A doctor that says `landlock: ABI 2` passes that check
while the kernel will silently skip network rules. On a stock Linux host this
rarely bites because 6.7+ is common; inside WSL it is the common case. The
port closes this by demanding ABI 4 or newer whenever a network policy is
configured, which is a stricter and more honest reading of the same report.

## The binfmt question

WSL's Windows interop is a binfmt_misc handler: the kernel routes PE
executables to /init, which launches them on the Windows side.
CONFIG_BINFMT_MISC is on, and the registration is kernel-wide. A container
root filesystem has no /init, so exec of a PE from inside a container should
fail with ENOENT after the handler matches; whether it actually fails is a
measurement, not a deduction, and the battery records it.
