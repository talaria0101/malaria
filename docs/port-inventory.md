# What changed, measured

The question this repository exists to answer, in numbers. The baseline is
errand as imported (src/ is 23,895 lines of TypeScript, 104 files, zero
`Deno.build.os` references: the Linux assumption is real but never stated).
Everything here is diffed against that baseline, so the counts are honest
even where a change is one line.

## The shape of the answer

About 400 lines change, in 16 of 104 files, plus two new files. No module
gains a second implementation and no backend is abstracted: the port is
branches at the eight places where the hosts actually differ, one new module
that names those places, and honest reporting where a guarantee cannot be
carried across.

## File by file

| File | Lines | What and why |
| --- | ---: | --- |
| src/platform.ts | +92 | New. The OS fact (`Deno.build.os`), process liveness on Windows (tasklist, since Deno.kill with anything but termination is refused there and negative pids throw), and the tree kill (taskkill /T /F, since there are no signalable process groups). |
| src/config/load.ts | 44 | Config search gains Windows spellings: %APPDATA% first, USERPROFILE honoured as home, ProgramData for the system path. Injected host flag keeps it testable on every platform. |
| src/sandbox/podman.ts | 81 | Volumes drop `:Z` on Windows (the machine has no SELinux to relabel with); the capability report becomes a pure function and, on Windows, names the machine context and states the Hyper-V firewall gap instead of claiming the host is closed. |
| src/sandbox/spawn.ts | 27 | setsid exists only where process groups do; on Windows the launcher starts directly and the tree kill replaces the group signal. |
| src/sandbox/bailey.ts | 28 | The doctor parser now reads the Landlock ABI, and a networked session is refused below ABI 4, because the tool negotiates down instead of failing and WSL2 kernels below 6.7 would run sessions with egress policy silently skipped. |
| src/main.ts | 30 | New `doctor` subcommand: the startup probe without needing a served channel, which matters most where the sandbox stack is new. |
| src/lock.ts | 17 | Liveness probing delegates to the platform module instead of assuming a signal. |
| src/provider/models.ts | 7 | Personal-home lookup honours USERPROFILE; an APPDATA candidate is added for the agent's own store. |
| src/session/pr.ts | 2 | git's environment falls back to USERPROFILE for HOME. |
| tests (5 files) | +195 | Windows spellings of the config search, the machine-context capability report, the ABI refusal, path translation across the POSIX-inside/Windows-outside boundary, and process-existence injection. |
| docs + research + experiments | +~700 | docs/windows.md; three research notes with sources and dates; the CI battery and its Deno probes. |

## What did not change, on purpose

- The sandbox contract: `WORKSPACE_PATH` stays `/workspace` and `STATE_PATH`
  stays `/state` under every backend, so the agent sees the same interior on
  every host, and the inside/outside path translation in `paths.ts` needed
  no code at all, only tests that pin it per platform.
- The policy generator, the admission queue, the chat gateway, the session
  lifecycle, the interface: none of them knew they were on Linux, so none of
  them had to learn.
- FORBIDDEN_ARGS: `--privileged`, `--network=host` and friends are refused
  identically; the machine context changes what the network flags can
  promise, not which flags would undo the point.
- The delegate request protocol: the agent writes files into its own state
  directory and the daemon answers; nothing in that is platform-shaped.

## The things that are not code

The two honest-enforcement changes matter more than their line counts. A
port that silently kept saying "host services are unreachable" on Windows
would be claiming a guarantee the stack cannot verify, and the daemon's whole
design says that is the one sin a sandbox must not commit. The same logic
produced the Landlock ABI refusal: a session that runs with its network
policy skipped is worse than one that refuses to start.
