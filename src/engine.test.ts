/**
 * Engine tests: real TCP over loopback, real files, real SHA-256 verification.
 * Runs via `node --test` against the compiled dist output.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { mkdtemp, rm, writeFile, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sendFiles, startReceiver } from "./engine.js";
import { sanitizeRelativePath } from "./protocol.js";

/** crypto.getRandomValues caps at 65536 bytes per call — fill in chunks. */
function randomBuf(size: number): Buffer {
  const buf = Buffer.alloc(size);
  for (let i = 0; i < size; i += 65536) {
    webcrypto.getRandomValues(buf.subarray(i, Math.min(i + 65536, size)));
  }
  return buf;
}

async function withDirs<T>(fn: (src: string, dest: string) => Promise<T>): Promise<T> {
  const src = await mkdtemp(join(tmpdir(), "hs-src-"));
  const dest = await mkdtemp(join(tmpdir(), "hs-dst-"));
  try {
    return await fn(src, dest);
  } finally {
    await rm(src, { recursive: true, force: true });
    await rm(dest, { recursive: true, force: true });
  }
}

test("transfers files with byte-exact content and verified hashes", async () => {
  await withDirs(async (src, dest) => {
    const payload = randomBuf(8 * 1024 * 1024);
    const p1 = join(src, "a.bin");
    const p2 = join(src, "b.bin");
    await writeFile(p1, payload);
    await writeFile(p2, payload.subarray(0, 1024));

    const rx = await startReceiver(dest, { streams: 2 });
    const rxDone = rx.done;
    const result = await sendFiles([p1, p2], { label: "loopback", host: "127.0.0.1", port: rx.address.port });
    const received = await rxDone;
    rx.stop();

    assert.equal(received.length, 2);
    assert.equal(result.files, 2);
    assert.equal(result.bytes, payload.length + 1024);

    const got = await readFile(join(dest, "a.bin"));
    assert.ok(got.equals(payload), "content must be byte-identical");
    await stat(join(dest, "b.bin"));
  });
});

test("resumes a partial file instead of restarting", async () => {
  await withDirs(async (src, dest) => {
    const payload = randomBuf(6 * 1024 * 1024);
    const p = join(src, "resume.bin");
    await writeFile(p, payload);

    // Simulate a partial previous attempt: first 2 MiB already on disk.
    const { mkdir, writeFile: wf } = await import("node:fs/promises");
    await mkdir(dest, { recursive: true });
    await wf(join(dest, "resume.bin"), payload.subarray(0, 2 * 1024 * 1024));

    const rx = await startReceiver(dest, { streams: 2 });
    const rxDone = rx.done;
    const result = await sendFiles([p], { label: "loopback", host: "127.0.0.1", port: rx.address.port });
    await rxDone;
    rx.stop();

    // Bytes over the wire = total minus the resume offset.
    assert.equal(result.bytes, payload.length - 2 * 1024 * 1024);
    const got = await readFile(join(dest, "resume.bin"));
    assert.ok(got.equals(payload), "resumed file must be byte-identical");
  });
});

test("skips files the receiver already has (hash match)", async () => {
  await withDirs(async (src, dest) => {
    const payload = randomBuf(1024);
    const p = join(src, "dup.bin");
    await writeFile(p, payload);

    const rx = await startReceiver(dest, { streams: 1 });
    const first = await sendFiles([p], { label: "loopback", host: "127.0.0.1", port: rx.address.port });
    const receivedFirst = await rx.done;
    rx.stop();
    assert.equal(first.files, 1);
    assert.equal(receivedFirst.length, 1);

    // Second identical batch: receiver already has it, zero data bytes flow.
    const rx2 = await startReceiver(dest, { streams: 1 });
    const second = await sendFiles([p], { label: "loopback", host: "127.0.0.1", port: rx2.address.port });
    const receivedSecond = await rx2.done;
    rx2.stop();
    assert.equal(second.bytes, 0);
    assert.equal(second.files, 1);
    assert.equal(receivedSecond.length, 1);
  });
});

test("zero-byte files arrive as zero-byte files", async () => {
  await withDirs(async (src, dest) => {
    const p = join(src, "empty.bin");
    await writeFile(p, Buffer.alloc(0));
    const rx = await startReceiver(dest, { streams: 1 });
    const rxDone = rx.done;
    const result = await sendFiles([p], { label: "loopback", host: "127.0.0.1", port: rx.address.port });
    await rxDone;
    rx.stop();
    assert.equal(result.files, 1);
    const st = await stat(join(dest, "empty.bin"));
    assert.equal(st.size, 0);
  });
});

test("rejects path traversal attempts", () => {
  assert.throws(() => sanitizeRelativePath("../etc/passwd"));
  assert.throws(() => sanitizeRelativePath("a/../../etc/passwd"));
  assert.throws(() => sanitizeRelativePath("/absolute/path"));
  assert.throws(() => sanitizeRelativePath(""));
  assert.throws(() => sanitizeRelativePath("a\0b"));
  assert.equal(sanitizeRelativePath("docs/report.pdf"), "docs/report.pdf");
  assert.equal(sanitizeRelativePath("win\\style\\path.txt"), "win/style/path.txt");
});

test("declined offers are reported, not fatal", async () => {
  await withDirs(async (src, dest) => {
    const p1 = join(src, "yes.bin");
    const p2 = join(src, "no.bin");
    await writeFile(p1, Buffer.alloc(4096, 1));
    await writeFile(p2, Buffer.alloc(4096, 2));

    const rx = await startReceiver(dest, {
      streams: 1,
      confirmOffer: (offer) => offer.path !== "no.bin",
    });
    const rxDone = rx.done;
    const result = await sendFiles([p1, p2], { label: "loopback", host: "127.0.0.1", port: rx.address.port });
    const received = await rxDone;
    rx.stop();

    assert.equal(result.files, 1);
    assert.equal(received.length, 1);
    await stat(join(dest, "yes.bin"));
    await assert.rejects(stat(join(dest, "no.bin")));
  });
});
