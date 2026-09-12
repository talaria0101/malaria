// deno-lint-ignore-file no-console
/**
 * Runtime behaviour probes for errand under Windows.
 *
 * Every probe records what happened rather than asserting what should: the
 * point is to measure the platform so the port can be written against facts.
 * Run with `deno run -A experiments/windows/deno_probes.ts <outfile>`.
 */

import { writeFile } from "node:fs/promises";

interface Probe {
  name: string;
  result: string;
}

const probes: Probe[] = [];

async function probe(
  name: string,
  fn: () => string | Promise<string>,
): Promise<void> {
  try {
    probes.push({ name, result: await fn() });
  } catch (error) {
    probes.push({
      name,
      result: `threw: ${(error as Error).constructor.name}: ${(error as Error).message}`,
    });
  }
  console.log(`${name}: ${probes[probes.length - 1]?.result}`);
}

function firstLine(text: string): string {
  return text.trim().split("\n")[0]?.slice(0, 120) ?? "";
}

await probe("deno.build.os", () => Deno.build.os);
await probe("deno.version", () => Deno.version.deno);
await probe("execPath", () => Deno.execPath());

await probe("env: USERPROFILE/HOME/APPDATA", () => {
  const e = Deno.env.toObject();
  return JSON.stringify({
    USERPROFILE: e.USERPROFILE ? "set" : "unset",
    HOME: e.HOME ? "set" : "unset",
    APPDATA: e.APPDATA ? "set" : "unset",
    PATHEntries: e.PATH?.split(";").length ?? 0,
  });
});

await probe("Deno.Command resolves podman from PATH", async () => {
  const c = new Deno.Command("podman", { args: ["--version"] });
  const out = await c.output();
  return `code ${out.code}, ${firstLine(new TextDecoder().decode(out.stdout))}`;
});

await probe("Deno.Command resolves a .cmd shim (deno.cmd style)", async () => {
  // errand must be able to run programs the operator put on PATH; on Windows
  // some of those are .cmd shims, which CreateProcess does not run directly.
  const c = new Deno.Command("git", { args: ["--version"], stderr: "piped" });
  const out = await c.output();
  return `code ${out.code}, ${firstLine(new TextDecoder().decode(out.stdout))}`;
});

await probe("child.kill('SIGTERM') on Windows", async () => {
  const c = new Deno.Command("ping", { args: ["-n", "30", "127.0.0.1"], stdout: "null" });
  const child = c.spawn();
  child.kill("SIGTERM");
  const status = await child.status;
  return `exited with ${status.code} after SIGTERM`;
});

await probe("Deno.kill(pid, 'SIGURG') on Windows", () => {
  const c = new Deno.Command("ping", { args: ["-n", "30", "127.0.0.1"], stdout: "null" });
  const child = c.spawn();
  try {
    Deno.kill(child.pid, "SIGURG");
    child.kill("SIGKILL");
    return "no error thrown";
  } catch (error) {
    child.kill("SIGKILL");
    return `threw: ${(error as Error).message}`;
  }
});

await probe("Deno.kill with negative pid on Windows", () => {
  const c = new Deno.Command("ping", { args: ["-n", "30", "127.0.0.1"], stdout: "null" });
  const child = c.spawn();
  try {
    Deno.kill(-child.pid, "SIGTERM");
    child.kill("SIGKILL");
    return "no error thrown";
  } catch (error) {
    child.kill("SIGKILL");
    return `threw: ${(error as Error).message}`;
  }
});

await probe("addSignalListener('SIGTERM')", () => {
  const handler = () => {};
  Deno.addSignalListener("SIGTERM", handler);
  Deno.removeSignalListener("SIGTERM", handler);
  return "registered and removed";
});

await probe("addSignalListener('SIGINT')", () => {
  const handler = () => {};
  Deno.addSignalListener("SIGINT", handler);
  Deno.removeSignalListener("SIGINT", handler);
  return "registered and removed";
});

await probe("Deno.serve on 127.0.0.1", async () => {
  const server = Deno.serve({ hostname: "127.0.0.1", port: 18777 }, () => new Response("ok"));
  const response = await fetch("http://127.0.0.1:18777/");
  const body = await response.text();
  await server.shutdown();
  return `served ${body}`;
});

await probe("chmodSync then stat mode", () => {
  const path = `${Deno.env.get("TEMP") ?? "."}/errand-chmod-probe.txt`;
  Deno.writeTextFileSync(path, "x");
  Deno.chmodSync(path, 0o600);
  const info = Deno.statSync(path);
  Deno.removeSync(path);
  return `mode after chmod 0600: ${info.mode?.toString(8)}`;
});

await probe("symlinkSync", async () => {
  const dir = `${Deno.env.get("TEMP") ?? "."}/errand-symlink-probe`;
  await Deno.mkdir(dir, { recursive: true });
  try {
    Deno.symlinkSync(`${dir}/target`, `${dir}/link`);
    Deno.removeSync(`${dir}/link`);
    return "created";
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
});

await probe("realPathSync reports actual casing", async () => {
  const dir = `${Deno.env.get("TEMP") ?? "."}/ERRAND-cAsE-Probe`;
  await Deno.mkdir(dir, { recursive: true });
  try {
    return Deno.realPathSync(`${dir.toLowerCase()}`);
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
});

await probe("writeTextFile newline handling", () => {
  const path = `${Deno.env.get("TEMP") ?? "."}/errand-newline-probe`;
  Deno.writeTextFileSync(path, "a\nb\n");
  const bytes = Deno.readFileSync(path);
  Deno.removeSync(path);
  return `bytes: ${[...bytes].join(",")}`;
});

await probe("path separators", async () => {
  // What the daemon's own path logic sees. The sandbox interior is POSIX
  // regardless, so every inside/outside translation crosses this boundary.
  const { resolve, SEPARATOR } = await import("@std/path");
  return JSON.stringify({
    sep: SEPARATOR,
    resolveOfWorkspace: resolve("C:\\proj", "/workspace/x"),
  });
});

const outfile = Deno.args[0];
if (outfile !== undefined) {
  await writeFile(outfile, `${JSON.stringify(probes, null, 2)}\n`);
  console.log(`written to ${outfile}`);
}
