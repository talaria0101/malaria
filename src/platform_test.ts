import { assertEquals } from "@std/assert";
import { IS_WINDOWS, processExists } from "./platform.ts";

Deno.test("a live process is reported as existing", () => {
  assertEquals(processExists(Deno.pid), true);
});

Deno.test("nonsense process ids are refused before anything is asked", () => {
  assertEquals(processExists(0), false);
  assertEquals(processExists(-1), false);
  assertEquals(processExists(999_999_999), false);
  assertEquals(processExists(Number.NaN), false);
});

Deno.test("on Windows the answer comes from the process listing", () => {
  // Injected rather than assumed: this runs on every host, and only the
  // Windows branch consults the lister, so asserting what the lister was
  // asked and how its verdict is read needs no Windows to prove.
  const asked: string[][] = [];
  const exists = processExists(4242, (program, args) => {
    asked.push([program, ...args]);
    return true;
  }, true);
  assertEquals(exists, true);
  assertEquals(asked.length, 1);
  assertEquals(asked[0]?.[0], "tasklist");
  assertEquals(asked[0]?.includes("/FI"), true);

  const absent = processExists(4242, () => false, true);
  assertEquals(absent, false);
});

Deno.test("on Linux the lister is never consulted", () => {
  let consulted = false;
  processExists(Deno.pid, (_program, _args) => {
    consulted = true;
    return true;
  }, false);
  assertEquals(consulted, IS_WINDOWS);
});
