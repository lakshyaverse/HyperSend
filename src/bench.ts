/**
 * Localhost benchmark. Measures the full engine stack (disk → hash → TCP →
 * disk → hash-verify) over loopback, which upper-bounds what any radio link
 * could deliver through this software. If this number is low, the radio is
 * never the bottleneck — fix the software first.
 */

import { webcrypto } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { sendFiles, startReceiver } from "./engine.js";

export type BenchResult = {
  files: number;
  bytes: number;
  elapsedMs: number;
  mibsPerSec: number;
  verified: boolean;
};

export async function runLocalBench(sizeMb = 256): Promise<BenchResult> {
  const srcDir = await mkdtemp(join(tmpdir(), "hypersend-src-"));
  const destDir = await mkdtemp(join(tmpdir(), "hypersend-dst-"));

  try {
    // Two files: a big one to measure steady-state, a small one to exercise
    // multi-file accounting. Random bytes (incompressible, like real media).
    const randomChunk = (): Buffer => {
      const chunk = Buffer.alloc(65536);
      webcrypto.getRandomValues(chunk);
      return chunk;
    };
    const big = Buffer.alloc(sizeMb * 1024 * 1024);
    for (let i = 0; i < big.length; i += 65536) {
      randomChunk().copy(big, i);
    }
    const small = Buffer.alloc(1024 * 1024);
    for (let i = 0; i < small.length; i += 65536) {
      randomChunk().copy(small, i);
    }
    const bigPath = join(srcDir, "bench-big.bin");
    const smallPath = join(srcDir, "bench-small.bin");
    await writeFile(bigPath, big);
    await writeFile(smallPath, small);

    const rx = await startReceiver(destDir, { streams: 4 });
    try {
      const rxDone = rx.done;
      const sendPromise = sendFiles(
        [bigPath, smallPath],
        { label: "loopback", host: "127.0.0.1", port: rx.address.port },
        { streams: 4 },
      );
      const received = await rxDone;
      const result = await sendPromise;

      const verified =
        received.length === 2 &&
        received.every((f) => f.size === (f.path.includes("big") ? big.length : small.length));

      return { ...result, verified };
    } finally {
      rx.stop();
    }
  } finally {
    await rm(srcDir, { recursive: true, force: true });
    await rm(destDir, { recursive: true, force: true });
  }
}

// Direct invocation: `node dist/bench.js [sizeMB]`
if (process.argv[1] && import.meta.url.endsWith(basename(process.argv[1]))) {
  const sizeMb = Number.parseInt(process.argv[2] ?? "", 10) || 256;
  const t0 = Date.now();
  const r = await runLocalBench(sizeMb);
  const wall = (Date.now() - t0) / 1000;
  console.log(
    `hypersend bench: ${r.files} file(s), ${(r.bytes / 1024 ** 2).toFixed(0)} MB in ${wall.toFixed(2)}s ` +
      `→ ${r.mibsPerSec.toFixed(1)} MiB/s engine throughput (verified=${r.verified})`,
  );
}
