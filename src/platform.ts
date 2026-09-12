/**
 * Where one host differs from another.
 *
 * Everything here is a fact about the machine this daemon runs on, kept in
 * one place so the rest of the code can ask once instead of growing its own
 * platform branches. The sandbox interior is POSIX under every backend and on
 * every host: the agent sees /workspace and /state whatever the daemon runs
 * on, so this module is only about the outside of the boundary.
 */

/** The operating system this daemon runs on, as the runtime names it. */
export const OS = Deno.build.os;

/** Whether the daemon runs on Windows. */
export const IS_WINDOWS = OS === "windows";

/** The name of the external tree-kill tool on Windows. */
export const TASKKILL = "taskkill";

/** The name of the external process-listing tool on Windows. */
export const TASKLIST = "tasklist";

/**
 * Runs a program to completion and returns what it said.
 *
 * Synchronous, because both callers decide on a fact about a process that
 * may already be gone, and a promise would make the answer arrive after the
 * decision.
 */
export function runSync(
  program: string,
  args: readonly string[],
): { code: number; stdout: string } {
  try {
    const command = new Deno.Command(program, {
      args: [...args],
      stdout: "piped",
      stderr: "null",
      stdin: "null",
    });
    const { code, stdout } = command.outputSync();
    return { code, stdout: new TextDecoder().decode(stdout) };
  } catch {
    return { code: -1, stdout: "" };
  }
}

/**
 * Whether a process with this id exists on this host.
 *
 * Linux answers through a signal whose default disposition is to be ignored,
 * so the target is not disturbed by being asked about. Windows has no such
 * signal, and the runtime refuses anything but termination there, so the
 * same question goes to the system's own process listing instead.
 *
 * On Windows the answer is read from the listing rather than from the exit
 * code: the listing tool reports no match with a success code and a line of
 * prose, which is not a process.
 *
 * Being refused permission counts as running on Linux: the process is there,
 * it just belongs to somebody else.
 *
 * @param lister injected; the process-listing command used on Windows.
 * @param hostWindows injected; which host the question is asked on.
 */
export function processExists(
  pid: number,
  lister: (program: string, args: readonly string[]) => { code: number; stdout: string } = runSync,
  hostWindows: boolean = IS_WINDOWS,
): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  if (!hostWindows) {
    try {
      Deno.kill(pid, "SIGURG");
      return true;
    } catch (error) {
      return error instanceof Deno.errors.PermissionDenied;
    }
  }
  // The listing is CSV: "name","pid","session","session-number","memory".
  // The pid is the second field of some line.
  const { stdout } = lister(TASKLIST, ["/FI", `PID eq ${pid}`, "/NH", "/FO", "CSV"]);
  return stdout.split("\n").some((line) => {
    const fields = line.split(",");
    return (fields[1] ?? "").replace(/"/g, "").trim() === String(pid);
  });
}

/**
 * Ends a process and everything it started, on Windows.
 *
 * Windows has no process groups the runtime can signal, so a tree kill goes
 * through the system's own tool. The forceful form is the only form: a
 * graceful request would leave grandchildren behind holding the project
 * open, which is the failure this exists to prevent.
 *
 * @returns whether the tool exited cleanly.
 */
export function treeKill(pid: number): boolean {
  if (!IS_WINDOWS) return false;
  return runSync(TASKKILL, ["/PID", String(pid), "/T", "/F"]).code === 0;
}
