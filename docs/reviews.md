# The five reviews

Each pass had one lens and had to find or verify, not summarize. Findings
were fixed before the next pass started; what each one turned up is listed
here because a review that reports only "all clear" has not been read
closely enough to trust.

## 1. Reproducibility and re-derivation

Re-ran every locally runnable measurement and re-fetched every source the
research notes cite.

- The four WSL2 kernel configs were fetched again and grepped fresh:
  `CONFIG_SECURITY_LANDLOCK=y` present on 5.15, 6.6, and 6.18, matching the
  note.
- The runtime default-posture experiment was run again: Bun asked the
  kernel, Deno refused first. Same result as recorded.
- The battery was re-run five times across the session; every number quoted
  in the docs traces to a committed artifact under `experiments/results/`.

Finding: none. The claims re-derive.

## 2. Claim scope

Every claim was checked for the scope it actually earns: version, host,
configuration, and who measured it.

Findings, fixed:

- `docs/port-inventory.md` counted the pre-trim diff; recounted against the
  final tree (731 changed lines plus two new files, against 1,511 removed
  lines of interface) and split the port from the trim so neither number
  hides the other.
- The Windows volume-spelling probe had mangled its second case into a
  recording of an empty string; the recording said nothing and was allowed
  to look like a result. Fixed in the probe, re-measured.
- `research/podman-machine.md` hedged the network question as "expectation";
  it now states the measured behavior on a stock runner and keeps the gap,
  because the firewall is the operator's to change.
- The Landlock ABI probe on the battery's kernel returns EINVAL and no
  securityfs directory, contradicting the config file. Recorded as
  unresolved rather than explained away; bailey's own real-setup probe is
  the authority, and the daemon refuses on anything it cannot prove.

## 3. Consistency router

Cross-checked code, docs, schema, generated reference pages, and CI for
disagreement.

Findings, fixed:

- `deno task build` still passed `--include dist/web` to `deno compile`
  after the interface was trimmed; the binary build in CI failed on the
  missing directory.
- `docs/windows.md` still told Windows operators to run the deleted
  `build:web` task.
- `docs/deno.json` and the vitepress tree survived their own removal.
- `docs/index.md` and `docs/sandboxing.md` still promised a browser
  interface and a public-bind refusal that no longer exist.
- `docs/port-inventory.md` still listed the interface among the modules
  that did not change.
- One line of dead `import` from an earlier edit of `src/serve.ts`.

## 4. Security and adversarial

Asked what the port itself might have opened, and what the platform does to
the containment contract.

- Agent paths are POSIX; host paths are Windows. Drive-absolute agent paths
  (`C:\Windows`) fall through to project-relative and then refuse on the
  prefix check; traversal refuses; case differences refuse closed. The
  tests pin the Windows spellings and run on the Windows runner.
- No agent-controlled string reaches `taskkill`, `tasklist`, or podman
  arguments: session ids are daemon-generated integers-with-prefix, pids
  are numbers.
- The chat token crosses into neither the container (env is named, not
  inherited) nor the client (it inherits the daemon env, which holds it,
  but only `--env` lists enter the container). Unchanged from upstream.
- The delegate wrapper is executable inside a Windows-mounted state
  directory only because the drive mount maps files 0777. That is the same
  privilege the container already has; nothing is widened. Measured:
  `executed-ok`, and `CapEff` is zero, so an executable mount is not a
  capability grant.
- Executing a Windows binary from inside a container reaches the WSL
  binfmt handler and fails there: exit 1, nothing launched on Windows, the
  container carried on. Measured, and better than the deduction.
- Trimming the interface also removed the one local listener and its
  bind-address rules; the daemon now opens no listening socket at all.

## 5. Tests and continuous integration

The whole suite had to be green on both platforms, with every platform
branch exercised somewhere.

Findings, fixed:

- The Windows suite surfaced real bugs, not just test drift: display paths
  stripped only `/`, upload naming split only on `/`, and `tasklist`
  answers no-match with exit code 0, so liveness must read the listing.
- bailey's probe tests depended on the host having the pi agent; the
  runtime lookup is now injectable.
- `treeBytes` walked directories asynchronously from a background timer,
  so a walk started in one test completed inside another: leak-detector
  failures that moved between tests on roughly every third run, present in
  the pristine import as well. The walk is synchronous now, and eight
  consecutive full-suite runs are clean.
- A delegation test left the scheduler's backoff timer running; the
  backoff-timer leak predates the port and is fixed.
- One new test wrote its probe under a literal `/state`, which a GitHub
  runner cannot create; it uses a temp directory now.
- Final state: 609 tests green locally on Linux, the same suite green on
  the Windows runner, the Linux `deno task check` green, and the Windows
  binary built as an artifact on every push.
