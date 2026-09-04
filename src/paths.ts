import fs from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Bundle identifier of the macOS Messages app. */
export const MESSAGES_BUNDLE_ID = "com.apple.MobileSMS";

/** Messages.app's sandbox container. */
export function containerDir(): string {
  return join(homedir(), "Library", "Containers", MESSAGES_BUNDLE_ID, "Data");
}

/**
 * Default socket path.
 *
 * It lives inside the Messages container because the injected code is
 * sandboxed and cannot reach arbitrary paths — writes to /tmp are denied once
 * the app has finished launching.
 */
export function defaultSocketPath(): string {
  return join(containerDir(), "tmp", "imcore-bridge.sock");
}

/**
 * The installed package's root, found by walking up to the nearest
 * package.json rather than by counting directories.
 *
 * The depth is not a constant: it differs between running the build and
 * running the sources directly, and it changed once already when the compiled
 * layout moved up a level. A fixed number of `..` segments then resolves
 * somewhere outside the package entirely, and the only symptom is the dylib
 * being reported as missing from a path the user never configured.
 */
export function packageRoot(): string {
  const start = dirname(fileURLToPath(import.meta.url));
  for (let dir = start; ; ) {
    if (fs.existsSync(join(dir, "package.json"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return start;
    dir = parent;
  }
}

/** Path to the built dylib, relative to the installed package. */
export function defaultDylibPath(packageRoot: string): string {
  return join(packageRoot, "native", "build", "imcore-bridge.dylib");
}

/** The Messages executable, which must be exec'd directly to inject. */
export const MESSAGES_BINARY =
  "/System/Applications/Messages.app/Contents/MacOS/Messages";
