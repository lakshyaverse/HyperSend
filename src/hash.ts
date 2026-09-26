/**
 * SHA-256 helpers. Integrity is mandatory — LocalSend-style "it probably
 * arrived" is not acceptable for a transfer tool. Incremental hashing keeps
 * memory flat for arbitrarily large files.
 */

import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { pipeline } from "node:stream/promises";

export function newTransferId(): string {
  return randomUUID();
}

export function sha256File(path: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(path, { highWaterMark: 4 * 1024 * 1024 });
    stream.on("data", (chunk: string | Buffer) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

export function sha256Buffer(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}
