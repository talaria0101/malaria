# Deno or Bun for this daemon

Measured where I could, read where I could not, and written as a decision
rather than a survey.

## The measured part

Same script, reading a file with node:fs, no flags:

- Bun 1.4.0 read the file. It reported ENOENT, which is the file-missing
  error, meaning the kernel was asked. Bun grants every capability by
  default.
- Deno 2.5.6 refused before touching the file: `NotCapable: Requires read
  access`. Deno refuses by default and grants only what a flag names.

This is the whole argument in one experiment. errand is a daemon that holds a
chat token and a provider credential, spawns the sandbox that the untrusted
party runs in, and starts every run under an explicit permission set, which
the README presents as a property of the project rather than an
implementation detail. Moving it to a runtime whose default is the opposite
inverts the daemon's own posture, and the permission model Bun is building
(`--permission`, node's model) is still unshipped: pull request 35403 in
oven-sh/bun, opened 2026-07, is the flag surface, and 35789 records that
until it lands Bun refuses those flags rather than sandboxing. A daemon does
not wait on a runtime feature to keep its promise.

## The Windows part, which matters more here

The port needs from its runtime, on Windows:

- `Deno.Command` resolving `podman` from PATH. Rust's process machinery on
  which Deno builds resolves executables with PATH and the .exe suffix, and
  the probes in experiments/windows/deno_probes.ts run against the real
  podman install to confirm.
- Signals. lib.deno.ns.d.ts says plainly: on Windows only SIGINT, SIGBREAK,
  SIGTERM, SIGQUIT, SIGHUP, and SIGWINCH can have listeners. serve.ts
  registers SIGINT and SIGTERM, and the probes registered both for real on
  a Windows runner. What has no Windows meaning at all is the process
  group: `Deno.kill(pid, "SIGURG")` threw "Invalid signal" and a negative
  pid threw "Invalid pid" when the probe ran them, which is why liveness
  checking and tree killing needed Windows answers of their own.
- Cross compilation: `deno compile --target x86_64-pc-windows-msvc` produces
  errand.exe on the Linux CI job, so a Windows host needs no toolchain, same
  as the Linux story with dist/errand.

Bun cross-compiles to Windows too (`bun build --compile
--target=bun-windows-x64`), and Bun's Windows support has been real since
1.1. Where Bun would hurt this codebase specifically is the parts it does not
have a Deno-shaped answer for: Deno.Command's clearEnv, which the daemon uses
to keep the chat token out of children, is a documented Deno option whose
Bun equivalent would have to be re-verified; Deno.errors' typed taxonomy
(NotCapable, AlreadyExists) is load-bearing in lock.ts and load.ts; and
`deno task check` as the project's whole quality gate is Deno tooling. None
of that is a reason Bun could never work. It is a list of re-verification
with no counterweight, because the performance argument does not apply: this
is a long-running daemon whose hot path is a model provider round trip
measured in seconds. A faster runtime start saves nothing a person can feel.

## Decision

Keep Deno. The port keeps the daemon's permission set, keeps `deno task
check` green on both platforms, and adds the Windows binary to the same
build task family. Bun is recorded here as evaluated and declined, with the
reason, so the question does not have to be re-litigated by the next reader.
