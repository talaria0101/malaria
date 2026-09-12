import { assertEquals } from "@std/assert";
import { processExists } from "./platform.ts";

Deno.test("a live process is reported as existing", () => {
  assertEquals(processExists(Deno.pid), true);
});

Deno.test("nonsense process ids are refused before anything is asked", () => {
  assertEquals(processExists(0), false);
  assertEquals(processExists(-1), false);
  assertEquals(processExists(999_999_999), false);
  assertEquals(processExists(Number.NaN), false);
});

Deno.test("on Windows the answer is read from the listing, not the exit code", () => {
  const asked: string[][] = [];
  const listing = '"taskmgr","4242","Console","1","12,345 K"\r\n';
  const exists = processExists(4242, (_program, args) => {
    asked.push(["tasklist", ...args]);
    return { code: 0, stdout: listing };
  }, true);
  assertEquals(exists, true);
  assertEquals(asked.length, 1);
  assertEquals(asked[0]?.[0], "tasklist");
  assertEquals(asked[0]?.includes("/FI"), true);

  // The listing tool answers "no match" with a success code and prose, so
  // only the pid field decides.
  const absent = processExists(4242, () => ({
    code: 0,
    stdout: "INFO: no tasks are running which match the specified criteria.\r\n",
  }), true);
  assertEquals(absent, false);
});

Deno.test("the Linux branch never consults the process listing", () => {
  let consulted = false;
  processExists(Deno.pid, (_program, _args) => {
    consulted = true;
    return { code: 0, stdout: "" };
  }, false);
  assertEquals(consulted, false);
});
