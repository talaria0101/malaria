import { assertEquals } from "@std/assert";
import { join, resolve } from "@std/path";
import { hostPathUnder, within } from "./paths.ts";

const ROOT = "/projects/demo";

// resolve() spells the answer with the host's own separators and, on
// Windows, ahead of a drive letter. Comparing against resolve() of the same
// parts keeps the assertions about containment rather than about spelling.
function inside(root: string, relative: string): string {
  return resolve(root, relative);
}

Deno.test("a path inside the root resolves to an absolute path", () => {
  assertEquals(within(ROOT, "src/main.ts"), inside(ROOT, "src/main.ts"));
  assertEquals(within(ROOT, "./notes.md"), inside(ROOT, "notes.md"));
  assertEquals(within(ROOT, "a/../b.txt"), inside(ROOT, "b.txt"));
});

Deno.test("the root itself is inside it", () => {
  assertEquals(within(ROOT, "."), resolve(ROOT));
  assertEquals(within(ROOT, ROOT), resolve(ROOT));
});

Deno.test("a path that climbs out is refused", () => {
  assertEquals(within(ROOT, "../other/secret"), undefined);
  assertEquals(within(ROOT, "src/../../escaped"), undefined);
  assertEquals(within(ROOT, "/etc/passwd"), undefined);
});

/** A sibling sharing a prefix is not inside, however similar the string is. */
Deno.test("a sibling with the same prefix is not inside", () => {
  assertEquals(within(ROOT, "/projects/demo-other/file"), undefined);
  assertEquals(within("/projects/demo", "/projects/demoted"), undefined);
});

Deno.test("deep traversal is refused however it is spelled", () => {
  for (const path of ["../..", "a/b/../../../out", "./../out", "a/./../../out"]) {
    assertEquals(within(ROOT, path), undefined, path);
  }
});

Deno.test("a path the agent sees becomes a path on the host", () => {
  assertEquals(
    hostPathUnder("/workspace", ROOT, "/workspace/src/a.ts"),
    inside(ROOT, join("src", "a.ts")),
  );
  assertEquals(hostPathUnder("/workspace", ROOT, "src/a.ts"), inside(ROOT, join("src", "a.ts")));
  assertEquals(hostPathUnder("/workspace", ROOT, "/workspace"), resolve(ROOT));
});

Deno.test("an absolute path outside the workspace is read as project-relative", () => {
  assertEquals(
    hostPathUnder("/workspace", ROOT, "/etc/passwd"),
    inside(ROOT, join("etc", "passwd")),
  );
  assertEquals(hostPathUnder("/workspace", ROOT, "  "), undefined);
  assertEquals(hostPathUnder("/workspace", ROOT, ""), undefined);
});

Deno.test("an agent path under the workspace lands in a Windows project", () => {
  if (Deno.build.os !== "windows") return;

  const host = hostPathUnder("/workspace", "C:\\errand\\projects\\demo", "/workspace/src/main.ts");
  assertEquals(host, "C:\\errand\\projects\\demo\\src\\main.ts");
});

Deno.test("a Windows translation still refuses traversal", () => {
  if (Deno.build.os !== "windows") return;

  const host = hostPathUnder(
    "/workspace",
    "C:\\errand\\projects\\demo",
    "/workspace/../../secrets",
  );
  assertEquals(host, undefined);
});

Deno.test("an absolute path outside the workspace is read as project-relative, on Windows too", () => {
  if (Deno.build.os !== "windows") return;

  const host = hostPathUnder("/workspace", "C:\\errand\\projects\\demo", "/etc/passwd");
  assertEquals(host, "C:\\errand\\projects\\demo\\etc\\passwd");
});
