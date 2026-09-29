/**
 * Serve-mode tests: real HTTP + real TCP over loopback. The page must be
 * served, a browser-staged file must cross the wire to a real receiver, and
 * an incoming offer must surface in the GUI state where a decision by HTTP
 * completes the transfer.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { mkdtemp, rm, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServe } from "./serve.js";
import { startReceiver, sendFiles } from "./engine.js";

function randomBuf(size: number): Buffer {
  const buf = Buffer.alloc(size);
  for (let i = 0; i < size; i += 65536) {
    webcrypto.getRandomValues(buf.subarray(i, Math.min(i + 65536, size)));
  }
  return buf;
}

test("serve: page renders and /api/state responds", async () => {
  const dest = await mkdtemp(join(tmpdir(), "hs-srv-"));
  const serve = await startServe({ destDir: dest, uiPort: 0, port: 0 });
  try {
    const page = await fetch(`${serve.url}/`);
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.ok(html.includes("HyperSend"), "page carries the app identity");
    assert.ok(html.includes("/api/events"), "page wires the SSE stream");

    const state = (await (await fetch(`${serve.url}/api/state`)).json()) as {
      peers: unknown[];
      received: unknown[];
      offer: unknown;
    };
    assert.deepEqual(state.peers, []);
    assert.deepEqual(state.received, []);
    assert.equal(state.offer, null);
  } finally {
    await serve.stop();
    await rm(dest, { recursive: true, force: true });
  }
});

test("serve: staged browser file arrives on a real receiver", async () => {
  const dest = await mkdtemp(join(tmpdir(), "hs-srv-"));
  const rxDir = await mkdtemp(join(tmpdir(), "hs-rx-"));
  const serve = await startServe({ destDir: dest, uiPort: 0, port: 0 });
  // Plain receiver, no confirmOffer: auto-accepts. Isolates the staging path
  // (multipart → temp dir → wire → disk) from the GUI offer flow, which the
  // next test covers.
  const rx = await startReceiver(rxDir, {});
  const payload = randomBuf(3 * 1024 * 1024 + 7);
  try {
    // Multipart body exactly as the browser builds it.
    const boundary = "----hypersendtest" + Date.now();
    const pre = Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="host"\r\n\r\n127.0.0.1\r\n` +
        `--${boundary}\r\nContent-Disposition: form-data; name="port"\r\n\r\n${rx.address.port}\r\n` +
        `--${boundary}\r\nContent-Disposition: form-data; name="files"; filename="web%20note.txt"\r\n` +
        `Content-Type: application/octet-stream\r\n\r\n`,
    );
    const post = Buffer.from(`\r\n--${boundary}--\r\n`);
    const body = Buffer.concat([pre, payload, post]);

    const res = await fetch(`${serve.url}/api/send`, {
      method: "POST",
      headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
      body,
    });
    const out = (await res.json()) as { ok: boolean; files?: number; error?: string };
    assert.equal(out.ok, true, out.error ?? "send must succeed");

    const landed = await readFile(join(rxDir, "web note.txt"));
    assert.ok(landed.equals(payload), "byte-exact through stage → wire → disk");
    assert.equal(out.files, 1);
  } finally {
    rx.stop();
    await serve.stop();
    await rm(dest, { recursive: true, force: true });
    await rm(rxDir, { recursive: true, force: true });
  }
});

test("serve: incoming offer surfaces in state and a decision completes the transfer", async () => {
  const dest = await mkdtemp(join(tmpdir(), "hs-srv-"));
  const src = await mkdtemp(join(tmpdir(), "hs-src-"));
  const serve = await startServe({ destDir: dest, uiPort: 0, port: 0 });
  try {
    const payload = randomBuf(2 * 1024 * 1024);
    const p = join(src, "incoming.bin");
    await writeFile(p, payload);

    // The engine's confirmOffer (wired to the GUI prompt) parks the sender;
    // poll /api/state the way the page's fallback would.
    const sendPromise = sendFiles([p], { label: "loopback", host: "127.0.0.1", port: serve.controlPort });

    type OfferView = { transferId: string; path: string; size: number };
    let offer: OfferView | null = null;
    for (let i = 0; i < 100 && !offer; i++) {
      await new Promise((r) => setTimeout(r, 100));
      const state = (await (await fetch(`${serve.url}/api/state`)).json()) as { offer: OfferView | null };
      offer = state.offer;
    }
    assert.ok(offer, "offer must surface in /api/state");

    const decide = await fetch(`${serve.url}/api/offer/${offer.transferId}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ accept: true }),
    });
    assert.equal(decide.status, 200);

    const result = await sendPromise;
    assert.equal(result.files, 1);
    const st = await stat(join(dest, "incoming.bin"));
    assert.equal(st.size, payload.length);
  } finally {
    await serve.stop();
    await rm(dest, { recursive: true, force: true });
    await rm(src, { recursive: true, force: true });
  }
});
