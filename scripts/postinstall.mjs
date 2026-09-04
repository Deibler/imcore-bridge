#!/usr/bin/env node
/**
 * Best effort native build at install time.
 *
 * The dylib is compiled rather than shipped. A prebuilt binary that gets
 * injected into Messages.app is exactly the artifact nobody should accept from
 * a registry sight unseen, and it would have to be signed and arch matched
 * anyway. The sources and the Makefile are in the tarball; this compiles them
 * where the package landed.
 *
 * It NEVER fails the install. A machine without the command line tools, or one
 * installing with scripts disabled, is a perfectly ordinary case: the client
 * half of this package reads and talks to a running bridge and needs no dylib
 * at all. When the build has not happened, `injectMessages` says so and names
 * the command that fixes it.
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));

if (process.platform !== "darwin") process.exit(0);
if (!existsSync(join(root, "native", "Makefile"))) process.exit(0);

const result = spawnSync("make", ["-C", "native"], {
  cwd: root,
  stdio: ["ignore", "ignore", "pipe"],
  encoding: "utf8",
});

if (result.status === 0) process.exit(0);

const detail = result.error?.code === "ENOENT" ? "make is not on PATH" : "the compile failed";
process.stderr.write(
  `imcore-bridge: skipped the native build (${detail}).\n` +
    "  Sending needs it; reading and connecting to a running bridge do not.\n" +
    "  To build it later:  npx imcore-bridge build-native\n" +
    "  If clang is missing: xcode-select --install\n",
);
process.exit(0);
