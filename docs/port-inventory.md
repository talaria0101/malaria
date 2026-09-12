# What changed, measured

The question this repository exists to answer, in numbers. The baseline is
errand as imported: 23,472 lines of TypeScript in 102 files under src/, with
zero `Deno.build.os` references anywhere in it, which is the portability
story in one line. The Linux assumption is real and never stated.

Everything below is diffed against that baseline, so the counts are honest
even where a change is one line.

## The shape of the answer

The port itself is about 880 lines: 731 changed lines across 28 files, plus
two new files (145 lines) holding the one module that names where hosts
differ and its tests. No module gains a second implementation and no backend
is abstracted; the port is branches at the eight places where the hosts
actually differ, and honest reporting where a guarantee cannot be carried
across.

Separately, this repository carries less of errand than errand does. The web
interface (its server, its Svelte app, its configuration section, and the
documentation site that hosted it) went away: 1,511 lines of src/ plus the
web/ tree, none of it relevant to the sandbox question, all of it optional in
the daemon by design. With the trim, src/ is 22,313 lines in 98 files, and
the daemon lost nothing it needed to be the daemon.

## File by file

| File                                                                                    | Lines | What and why                                                                                                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------------------- | ----: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| src/platform.ts                                                                         |   +93 | New. The OS fact (`Deno.build.os`), process liveness on Windows (tasklist, since Deno.kill with anything but termination is refused there and negative pids throw, and the listing tool answers no-match with a success code, so the pid field decides), and the tree kill (taskkill /T /F, since there are no signalable process groups). |
| src/config/load.ts                                                                      |    44 | Config search gains Windows spellings: %APPDATA% first, USERPROFILE honoured as home, ProgramData for the system path. An injected host flag keeps it testable on every platform.                                                                                                                                                          |
| src/sandbox/podman.ts                                                                   |    81 | Volumes drop `:Z` on Windows (the machine has no SELinux to relabel with); the capability report becomes a pure function and, on Windows, names the machine context and states the Hyper-V firewall gap instead of claiming the host is closed.                                                                                            |
| src/sandbox/spawn.ts                                                                    |    27 | setsid exists only where process groups do; on Windows the launcher starts directly and the tree kill replaces the group signal.                                                                                                                                                                                                           |
| src/sandbox/bailey.ts                                                                   |    35 | The doctor parser now reads the Landlock ABI, and a networked session is refused below ABI 4, because the tool negotiates down instead of failing and WSL2 kernels below 6.7 would run sessions with egress policy silently skipped. The agent runtime lookup is injectable, so its probe tests stop depending on the host having pi.      |
| src/session/session.ts                                                                  |    27 | Two real Windows bugs the suite caught: display paths stripped only `/` from the project prefix, and upload naming split only on `/`, so a backslash path came through whole.                                                                                                                                                              |
| src/session/disk.ts                                                                     |    41 | treeBytes walks directories synchronously. The async walk outlived whatever started it, which tripped leak detection in tests by finishing inside the wrong one; a measurement may block briefly, it may not leak.                                                                                                                         |
| src/main.ts                                                                             |    32 | New `doctor` subcommand: the startup probe without needing a served channel, which matters most where the sandbox stack is new.                                                                                                                                                                                                            |
| src/lock.ts                                                                             |    17 | Liveness probing delegates to the platform module instead of assuming a signal.                                                                                                                                                                                                                                                            |
| src/config/schema.ts, validate.ts, serve.ts                                             |    97 | The interface's configuration and wiring removed with the interface.                                                                                                                                                                                                                                                                       |
| src/provider/models.ts, session/pr.ts, session/manager.ts, session/github.ts, daemon.ts |    16 | Personal-home lookup honours USERPROFILE; git's environment falls back to it; the interface's publicUrl plumbing removed with the interface.                                                                                                                                                                                               |
| tests (9 files)                                                                         |  +366 | Windows spellings of the config search; the machine-context capability report; the ABI refusal; path translation pinned per platform; process liveness by injected listing; the upload and display-path regressions.                                                                                                                       |
| research/, experiments/, docs/windows.md                                                | +~900 | The subject of the repository: three research notes with sources and dates, the CI battery and its Deno probes, and the port guide.                                                                                                                                                                                                        |

## What did not change, on purpose

- The sandbox contract: `WORKSPACE_PATH` stays `/workspace` and `STATE_PATH`
  stays `/state` under every backend, so the agent sees the same interior on
  every host, and the inside/outside path translation in `paths.ts` needed
  no code at all, only tests that pin it per platform.
- The policy generator, the admission queue, the chat gateway, the session
  lifecycle: none of them knew they were on Linux, so none of them had to
  learn.
- FORBIDDEN_ARGS: `--privileged`, `--network=host` and friends are refused
  identically; the machine context changes what the network flags can
  promise, not which flags would undo the point.
- The delegate request protocol: the agent writes files into its own state
  directory and the daemon answers; nothing in that is platform-shaped.

## The things that are not code

The two honest-enforcement changes matter more than their line counts. A
port that kept saying "host services are unreachable" on Windows would be
claiming a guarantee the stack cannot verify, and the daemon's whole design
says that is the one sin a sandbox must not commit. The same logic produced
the Landlock ABI refusal: a session that runs with its network policy
silently skipped is worse than one that refuses to start.
