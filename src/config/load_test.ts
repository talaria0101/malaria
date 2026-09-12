import { assert, assertEquals, assertStringIncludes, assertThrows } from "@std/assert";
import { configCandidates, configPath, loadConfig } from "./load.ts";
import { join } from "@std/path";
import { ConfigError } from "./schema.ts";

const VALID = JSON.stringify({
  chat: { token: "t", channelId: "c", allowedUserIds: ["u"] },
  agent: { provider: "anthropic", credentialName: "ANTHROPIC_API_KEY", credential: "k" },
  projectRoot: "/tmp/errand/projects",
  stateDir: "/tmp/errand/state",
});

/** Naming the file outright wins, so nothing has to be guessed at. */
Deno.test("the environment names the file, and nothing else is consulted", () => {
  assertEquals(configPath({ ERRAND_CONFIG: "/etc/errand.json" }, () => false), "/etc/errand.json");
  assertEquals(configCandidates({ ERRAND_CONFIG: "/somewhere.json" }), ["/somewhere.json"]);
});

Deno.test("a blank variable is not a path, so the search runs", () => {
  const looked = configCandidates({ ERRAND_CONFIG: "  ", HOME: "/home/amelia" });

  assertEquals(looked[0], "/home/amelia/.config/errand/config.json");
});

/**
 * A person's own configuration comes first, so running the daemon by hand on a
 * host that also serves one does not pick up the service's token.
 */
Deno.test("it looks in the account's config directory, then the system's", () => {
  assertEquals(configCandidates({ HOME: "/home/amelia" }), [
    "/home/amelia/.config/errand/config.json",
    "/etc/errand/config.json",
    "config.json",
  ]);
});

Deno.test("a chosen config root is honoured", () => {
  assertEquals(
    configCandidates({ HOME: "/home/amelia", XDG_CONFIG_HOME: "/home/amelia/cfg" })[0],
    "/home/amelia/cfg/errand/config.json",
  );
});

Deno.test("the first one that is actually there is the one used", () => {
  const env = { HOME: "/home/amelia" };

  assertEquals(
    configPath(env, (path) => path === "/etc/errand/config.json"),
    "/etc/errand/config.json",
  );
  assertEquals(configPath(env, (path) => path === "config.json"), "config.json");
  // With none of them there, the failure names the place most likely meant.
  assertEquals(configPath(env, () => false), "/home/amelia/.config/errand/config.json");
});

Deno.test("a valid file loads", () => {
  const config = loadConfig("/anywhere", () => VALID);
  assertEquals(config.chat.channelId, "c");
});

/** Three different failures, so three different things to do about them. */
Deno.test("a missing file says where it looked and what to do", () => {
  const error = assertThrows(
    () =>
      loadConfig(
        "/home/amelia/.config/errand/config.json",
        () => {
          throw new Deno.errors.NotFound("nope");
        },
        { HOME: "/home/amelia" },
      ),
    ConfigError,
  ) as ConfigError;

  const said = error.problems.join("\n");
  assertStringIncludes(said, "/home/amelia/.config/errand/config.json");
  assertStringIncludes(said, "/etc/errand/config.json");
  assertStringIncludes(said, "ERRAND_CONFIG");
});

Deno.test("a file that is not JSON is not reported as a field problem", () => {
  const error = assertThrows(() => loadConfig("/c.json", () => "{ nope"), ConfigError);
  assertStringIncludes(String(error), "not valid JSON");
});

Deno.test("a file that parses but says something impossible lists every reason", () => {
  const error = assertThrows(() => loadConfig("/c.json", () => "{}"), ConfigError) as ConfigError;
  assertEquals(error.problems.length > 3, true);
});

/** Windows keeps per-person configuration under the roaming profile. */
Deno.test("on Windows the application-data directory comes first", () => {
  const looked = configCandidates(
    {
      HOME: "/c/h",
      USERPROFILE: "C:\\Users\\amelia",
      APPDATA: "C:\\Users\\amelia\\AppData\\Roaming",
    },
    true,
  );

  // The separators in a joined path are the host's, so this asserts order
  // and the directories chosen rather than the exact spelling.
  assertEquals(looked.length, 4);
  assert(looked[0]?.includes("AppData\\Roaming"), looked[0]);
  assert(looked[0]?.endsWith(join("errand", "config.json")), looked[0]);
  assert(looked[1]?.includes(".config"), looked[1]);
});

Deno.test("on Windows the machine-wide root is ProgramData", () => {
  const looked = configCandidates({ APPDATA: "C:\\Users\\amelia\\AppData\\Roaming" }, true);

  assert(looked[2]?.includes("ProgramData"), looked[2]);
  assert(!looked[2]?.includes("Roaming"), looked[2]);
});

Deno.test("a named file still wins on Windows", () => {
  assertEquals(configCandidates({ ERRAND_CONFIG: "D:\\cfg.json" }, true), ["D:\\cfg.json"]);
});
