import fs from "node:fs";
import os from "node:os";
import { randomUUID } from "node:crypto";
import { basename, join, resolve } from "node:path";

import { ImcoreBridgeError } from "./errors.js";

/** A file could not be prepared for sending. */
export class AttachmentSendError extends ImcoreBridgeError {}

/**
 * Where outgoing files are staged before they are handed to the transfer
 * daemon.
 *
 * This has to be inside the attachment tree. The daemon uploads from a path it
 * can reach itself, and it will not reach into an arbitrary directory — a
 * transfer registered against a file elsewhere is accepted, reports no error,
 * and never uploads.
 *
 * `IMCORE_BRIDGE_STAGING_DIR` overrides it, which is for tests: pointing it
 * elsewhere means nothing will actually send.
 */
export function stagingRoot(): string {
  return (
    process.env["IMCORE_BRIDGE_STAGING_DIR"] ??
    join(os.homedir(), "Library", "Messages", "Attachments", "imcore-bridge")
  );
}

/**
 * Copies a file into the attachment tree, returning its staged path.
 *
 * Staging happens out here rather than inside Messages because Messages is
 * sandboxed: it reads the attachment tree freely but is refused writes into
 * it. Each file gets its own directory so two sends of the same name cannot
 * overwrite one another mid-upload.
 *
 * The copy is left in place afterwards. That matches what Messages does with
 * any file you send — the attachment tree is where sent files live, and
 * removing it would empty the bubble in the transcript.
 */
export function stageAttachment(path: string): string {
  const source = resolve(path.replace(/^~(?=$|\/)/, os.homedir()));

  let stats: fs.Stats;
  try {
    stats = fs.statSync(source);
  } catch {
    throw new AttachmentSendError(`no file at '${source}'`);
  }
  if (!stats.isFile()) {
    throw new AttachmentSendError(`'${source}' is not a file`);
  }

  const directory = join(stagingRoot(), randomUUID());
  try {
    fs.mkdirSync(directory, { recursive: true });
    const staged = join(directory, basename(source));
    fs.copyFileSync(source, staged);
    return staged;
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    throw new AttachmentSendError(`could not stage '${source}': ${reason}`);
  }
}
