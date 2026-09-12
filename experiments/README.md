# Experiments

Each run records JSON and a transcript into `results/`, which is committed,
so every number the docs quote traces to a file here.

The battery runs on a GitHub windows-latest runner, which ships WSL2
preinstalled. `windows/battery.ps1` installs podman (via chocolatey), brings
up its machine with the WSL provider, and measures what the port depends on:
the restricted-network flags against the machine hop and the Windows host,
volume spellings, keep-id and the drive-mount semantics, the relabel suffix,
read-only rootfs and tmpfs, per-container limits, exit-code relay and stdin
piping, the kernel's Landlock and binfmt surface, and write throughput
through the drive mount against the machine's own filesystem. Container
probes run script files rather than inline shell, because the Windows client
re-splits inline payloads.

`windows/deno_probes.ts` measures the Deno runtime surface on Windows:
signal listeners and the kill calls the lock and process-group code need,
PATH resolution for the podman client, newline handling, chmod and symlink
semantics, and how resolve() treats a POSIX path against a Windows root.

`windows/shape-b.ps1` installs a plain Ubuntu WSL distro with podman
natively, rootless under its own user, and repeats the reachability battery
there. It is the alternative arrangement to the podman machine.

To reproduce: dispatch the `wsl-battery` workflow, download the
`wsl-battery-results` artifact, and read it against `docs/windows.md`.
Anything the docs claim without an artifact or a cited source is a mistake;
the reviews in `docs/reviews.md` were run looking for exactly those.
