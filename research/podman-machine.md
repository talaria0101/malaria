# podman on Windows: what the machine actually is

Read from containers/podman's docs (podman-machine-init.1.md.in,
podman-run.1.md.in on main, fetched 2026-09-12) and the passt man page at
passt.top, then verified against a live podman machine on a Windows Server
2025 runner: the battery in experiments/windows/battery.ps1 is the
measurement, and anything below that the battery has not confirmed is marked
as expectation.

## The architecture, because everything else follows from it

`podman machine init` on Windows defaults to the WSL provider. The machine is
a WSL distro (named podman-machine-default) running a custom Fedora image,
not the CoreOS image the other providers use. Containers run inside that
distro, rootless, as the machine's own user. The Windows-side podman.exe is a
client: `podman run` from PowerShell drives the machine through its API
socket, so every flag errand passes is interpreted inside the machine by the
podman and pasta that live there, and version facts about the Windows
installation are facts about the client only.

Two consequences worth writing down:

1. Windows drives are automounted in the machine at /mnt, and the
   podman-machine-init man page says plainly that for WSL "passing --volume
   is redundant and has no effect" for the machine-level mounts, because
   everything is already visible under /mnt. Volume syntax in `podman run`
   with a Windows path is translated by the client into that mount namespace.
2. "The host" is now a chain, not a machine. From the container: pasta is the
   first hop and the machine's init namespace is the host pasta maps; the
   machine's eth0 rides the WSL NAT, whose gateway is the Windows host; and
   the Windows host's own network is beyond that. errand's restricted network
   flags were derived on native Linux, where "the host" is one hop. On this
   stack they close the machine hop and say nothing about the Windows hop.

## The restricted-network flags, re-derived for the machine context

errand passes `pasta:--map-host-loopback,none,--map-guest-addr,none`. From
passt.1: `--map-host-loopback none` means no address is translated to the
host, and it implies `--no-map-gw`, so connections aimed at the gateway
address are not remapped to the host either. On native Linux this is what
closes the path from the container to a service bound on the host.

In the machine, the container's gateway is pasta's own address inside the
machine, and the Windows host is not any address pasta maps. The Windows host
is the next route out: machine eth0 -> WSL NAT gateway. From pasta's point of
view that is ordinary outbound traffic to a routable address, not a host
mapping, so the flags do not and cannot close it. The same is true of
`host.containers.internal`, the name podman machine resolves for guests.

Whether the Windows host is reachable in practice therefore depends on what
sits between the machine and Windows: the Hyper-V firewall for WSL, a host
policy the daemon can neither read nor change. Measured on the battery's
Windows Server 2025 runner (Hyper-V firewall reporting NotConfigured, which
behaves as deny for this path): with the errand flags the machine hop closes,
with podman's default pasta it stays mapped, and the Windows host is
unreachable in both cases, while outbound internet and DNS keep working.
The measured difference the flags make is visible in the artifact: the
mapped address answers "connection refused" under the default network and
times out under the restricted one, which is the mapping being removed
rather than the path being filtered. The daemon still reports the Windows
hop as a gap, because the firewall is the operator's to change; what the
measurement adds is that a stock host starts closed.

## Volumes and the filesystem cost

A project root on C:\ is served to the container through the WSL drive mount
(9p over the WSL2 transport). Three consequences, all to be measured rather
than asserted: inotify does not work through it, permission bits are a
convention rather than an enforcement (chmod is recorded, not applied), and
throughput and latency are much worse than the machine's own ext4. The port
therefore documents C:\ project roots as functional but slower, and shows the
projectRoot-inside-WSL arrangement for operators who care. The battery times
a fixed write through both paths.
