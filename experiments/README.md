# Experiment scripts. Each run records JSON into results/.

The battery runs on a GitHub windows-latest runner, which ships WSL2 preinstalled. `battery.ps1` installs podman, brings up its machine with the WSL provider, and measures the behaviours the port depends on. `deno_probes.ts` measures the Deno runtime surface on Windows. `shape-b.ps1` measures podman installed natively inside a WSL distro, the alternative to the podman machine.
