import { test, expect } from "bun:test";
import fs from "node:fs";
import { join } from "node:path";

// The CLI is exercised as a process rather than imported, because what is
// being checked is what a user gets from a shell: the exit code, and that the
// answer arrives without a socket. Importing it would run `main` on load.

const ROOT = join(import.meta.dir, "..");
const ENTRY = join(ROOT, "src", "bin", "imcore-bridge.ts");
const SOURCE = fs.readFileSync(ENTRY, "utf8");

async function run(...args: string[]): Promise<{
  code: number;
  stdout: string;
  stderr: string;
}> {
  const child = Bun.spawn(["bun", ENTRY, ...args], {
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { code, stdout, stderr };
}

// Each of these ran the connect first and answered only once it had timed out,
// so the reply was `BridgeUnavailableError` no matter what was actually wrong.
// A CLI that cannot say what it is without a running Messages is not usable as
// the entry point to installing one.

test("--help prints the usage without needing a bridge", async () => {
  const { code, stdout } = await run("--help");
  expect(code).toBe(0);
  expect(stdout).toContain("imcore-bridge — automate the macOS Messages app");
  expect(stdout).toContain("imcore-bridge launch");
});

test("no arguments prints the usage too", async () => {
  const { code, stdout } = await run();
  expect(code).toBe(0);
  expect(stdout).toContain("Usage:");
});

test("--version prints what the manifest says", async () => {
  const manifest: { version: string } = JSON.parse(
    fs.readFileSync(join(ROOT, "package.json"), "utf8"),
  );
  const { code, stdout } = await run("--version");
  expect(code).toBe(0);
  expect(stdout.trim()).toBe(manifest.version);
});

test("a misspelled command is refused rather than dialled", async () => {
  const { code, stderr, stdout } = await run("chatz", "--limit", "5");
  expect(code).toBe(2);
  expect(stderr).toContain("unknown command 'chatz'");
  // The complaint is about the word, not about the socket.
  expect(stderr).not.toContain("BridgeUnavailable");
  expect(stdout).toContain("Usage:");
});

// The accepted commands are read out of the usage text, so one can never be
// accepted without being documented. This is the other direction: a `case`
// added to the switch and left out of the usage text would be unreachable, and
// nothing else would notice.
test("every command the CLI implements is one the usage text lists", () => {
  const usage = SOURCE.slice(
    SOURCE.indexOf("const USAGE"),
    SOURCE.indexOf("const COMMANDS"),
  );
  const documented = new Set(
    [...usage.matchAll(/^ {2}imcore-bridge ([a-z-]+)/gm)].map((m) => m[1]!),
  );

  const body = SOURCE.slice(SOURCE.indexOf("async function main"));
  // Two shapes, both read out of the source rather than listed here. Most
  // commands are a `case` in the switch; the few that need no connection
  // (`launch`, `build-native`) are handled before it as an equality check.
  // Naming them here instead would be a list to keep in step with the code,
  // and the whole point of this test is that no such list exists.
  const implemented = [
    ...[...body.matchAll(/^ {6}case "([a-z-]+)"/gm)].map((m) => m[1]!),
    ...[...body.matchAll(/^ {2}if \(command === "([a-z-]+)"\)/gm)].map((m) => m[1]!),
  ];

  expect(implemented.filter((command) => !documented.has(command))).toEqual([]);
  expect(documented.size).toBe(implemented.length);
});
