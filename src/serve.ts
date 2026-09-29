/**
 * `hypersend serve` — the browser GUI.
 *
 * One process plays every role: it BEACONS (so Mac/Android/other senders see
 * this machine), LISTENS as a receiver (offers surface in the browser as a
 * prompt), WATCHES for peers (the Devices panel fills live over SSE), and
 * SENDS whatever the user stages in the page. No framework, no dependencies:
 * the HTTP server, the SSE stream and the multipart upload parser are all
 * hand-rolled — the engine underneath is the exact same one the CLI and the
 * Mac app drive.
 *
 * Multipart bodies are buffered in memory, so staging is capped (512 MB by
 * default, HYPERSEND_MAX_UPLOAD to change). Bigger files belong on the CLI,
 * which streams straight from disk.
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { hostname, networkInterfaces } from "node:os";
import { basename, join } from "node:path";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { once } from "node:events";
import { DEFAULT_PORT } from "./protocol.js";
import { startBeacon, startBeaconWatcher, type DiscoveredPeer } from "./discovery.js";
import { sendFiles, startReceiver, type EngineOptions, type Progress, type ReceivedFile } from "./engine.js";
import { PAGE } from "./webui.js";

export type ServeOptions = {
  /** Destination for files received through the GUI. */
  destDir: string;
  /** HTTP port of the page itself. Default 44020, falling back to ephemeral. */
  uiPort?: number | undefined;
  /** Control/data ports for the transfer engine (same meaning as receive mode). */
  port?: number | undefined;
  dataPort?: number | undefined;
  streams?: number | undefined;
  /** Beacon name; defaults to the machine's hostname. */
  name?: string | undefined;
  /** Cap for browser-staged uploads, in bytes. */
  maxUploadBytes?: number | undefined;
};

export type ServeHandle = {
  /** The URL to open in a browser. */
  url: string;
  /** The engine's control port — what senders dial (the beacon advertises it). */
  controlPort: number;
  stop: () => Promise<void>;
};

type TransferProgress = {
  fileName: string;
  bytesDone: number;
  bytesTotal: number;
  mibsPerSec: number;
  perPath: Array<{ label: string; bytes: number; chunks: number }>;
};

type UiState = {
  peers: DiscoveredPeer[];
  received: Array<{ name: string; size: number }>;
  offer: { transferId: string; path: string; size: number } | null;
  transfer: TransferProgress | null;
};

const SSE_PING_MS = 25_000;

function ownAddresses(): Set<string> {
  const out = new Set<string>(["127.0.0.1", "::1"]);
  for (const list of Object.values(networkInterfaces())) {
    for (const ni of list ?? []) out.add(ni.address);
  }
  return out;
}

/** Minimal multipart/form-data parser for the staging upload. */
function parseMultipart(
  body: Buffer,
  boundary: string,
): { fields: Record<string, string>; files: Array<{ name: string; data: Buffer }> } {
  const fields: Record<string, string> = {};
  const files: Array<{ name: string; data: Buffer }> = [];
  const delim = Buffer.from(`--${boundary}`);
  let pos = body.indexOf(delim);
  if (pos === -1) return { fields, files };
  pos += delim.length;
  for (;;) {
    // End marker: "--" right after the delimiter.
    if (body.slice(pos, pos + 2).toString() === "--") break;
    pos += 2; // skip CRLF after the boundary
    const headEnd = body.indexOf("\r\n\r\n", pos);
    if (headEnd === -1) break;
    const headers = body.slice(pos, headEnd).toString("utf8");
    const next = body.indexOf(delim, headEnd + 4);
    if (next === -1) break;
    const content = body.slice(headEnd + 4, next - 2); // strip trailing CRLF

    const disposition = headers.split("\r\n").find((l) => l.toLowerCase().startsWith("content-disposition:"));
    const nameMatch = disposition?.match(/name="([^"]*)"/);
    const fileMatch = disposition?.match(/filename="([^"]*)"/);
    if (fileMatch) {
      files.push({ name: decodeURIComponent(fileMatch[1] ?? "file"), data: content });
    } else if (nameMatch) {
      fields[nameMatch[1]!] = content.toString("utf8");
    }
    pos = next + delim.length;
  }
  return { fields, files };
}

export async function startServe(opts: ServeOptions): Promise<ServeHandle> {
  const maxUpload = opts.maxUploadBytes ?? 512 * 1024 * 1024;
  const name = opts.name ?? hostname();
  const own = ownAddresses();

  // ── engine: receiver + beacon + watcher ────────────────────────────────
  // Built conditionally: exactOptionalPropertyTypes forbids passing an
  // explicit `undefined` into an optional field.
  const engineOpts: EngineOptions = {};
  if (opts.port !== undefined) engineOpts.port = opts.port;
  if (opts.dataPort !== undefined) engineOpts.dataPort = opts.dataPort;
  if (opts.streams !== undefined) engineOpts.streams = opts.streams;

  const receivedList: Array<{ name: string; size: number }> = [];
  let pendingOffer: { offer: { transferId: string; path: string; size: number }; decide: (v: boolean) => void } | null = null;
  let lastTransfer: TransferProgress | null = null;

  engineOpts.onReceived = (f: ReceivedFile) => {
    receivedList.push({ name: basename(f.path), size: f.size });
    if (receivedList.length > 50) receivedList.shift();
    broadcast();
  };
  engineOpts.confirmOffer = ({ path, size, transferId }) =>
    new Promise<boolean>((res) => {
      const timer = setTimeout(() => {
        pendingOffer = null;
        broadcast();
        res(false); // a person takes ~2 min; past that, decline on their behalf
      }, 120_000);
      pendingOffer = {
        offer: { transferId, path, size },
        decide: (accept) => {
          clearTimeout(timer);
          pendingOffer = null;
          broadcast();
          res(accept);
        },
      };
      broadcast();
    });

  const rx = await startReceiver(opts.destDir, engineOpts);
  const beacon = startBeacon(rx.address.port, name);
  const watcher = startBeaconWatcher({
    onChange: () => broadcast(),
  });
  void rx.done.catch(() => {}); // sessions end; serve mode outlives them

  // ── state + SSE fan-out ────────────────────────────────────────────────
  const clients = new Set<ServerResponse>();
  const snapshot = (): UiState => ({
    peers: watcher.peers().filter((p) => !own.has(p.host)),
    received: receivedList.slice(),
    offer: pendingOffer?.offer ?? null,
    transfer: lastTransfer,
  });

  const broadcast = (): void => {
    const frame = `data: ${JSON.stringify(snapshot())}\n\n`;
    for (const res of clients) res.write(frame);
  };

  // ── http ───────────────────────────────────────────────────────────────
  const http: Server = createServer((req, res) => {
    void handle(req, res).catch((err) => {
      if (!res.headersSent) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }));
      } else {
        res.end();
      }
    });
  });

  async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://local");

    if (req.method === "GET" && url.pathname === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(PAGE);
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/events") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      res.write(`data: ${JSON.stringify(snapshot())}\n\n`);
      clients.add(res);
      const ping = setInterval(() => res.write(": ping\n\n"), SSE_PING_MS);
      req.on("close", () => {
        clearInterval(ping);
        clients.delete(res);
      });
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/state") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(snapshot()));
      return;
    }

    if (req.method === "POST" && url.pathname.startsWith("/api/offer/")) {
      const transferId = url.pathname.split("/").pop() ?? "";
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}") as { accept?: boolean };
      if (pendingOffer?.offer.transferId === transferId) {
        pendingOffer.decide(body.accept === true);
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } else {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: "no such offer" }));
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/send") {
      const declared = Number(req.headers["content-length"] ?? 0);
      if (declared > maxUpload) {
        res.writeHead(413, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: `upload too large (cap ${Math.round(maxUpload / 1048576)} MB — use the CLI for bigger files)` }));
        return;
      }
      const chunks: Buffer[] = [];
      let total = 0;
      for await (const c of req) {
        chunks.push(c as Buffer);
        total += (c as Buffer).length;
        if (total > maxUpload) {
          res.writeHead(413, { "content-type": "application/json" });
          res.end(JSON.stringify({ ok: false, error: "upload too large" }));
          return;
        }
      }
      const body = Buffer.concat(chunks);
      // Browsers quote the boundary; hand-built clients may not — read both.
      const m = /boundary=(?:"([^"]+)"|([^;\s]+))/.exec(req.headers["content-type"] ?? "");
      const boundary = m?.[1] ?? m?.[2];
      if (!boundary) {
        res.writeHead(400, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: "expected multipart/form-data" }));
        return;
      }
      const { fields, files } = parseMultipart(body, boundary);
      const host = fields.host;
      const port = Number.parseInt(fields.port ?? "", 10) || DEFAULT_PORT;
      if (!host || files.length === 0) {
        res.writeHead(400, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: "need a device and at least one file" }));
        return;
      }

      // Stage to a temp dir, send, clean up. Progress streams to every
      // browser via SSE while the POST itself stays open until the batch ends.
      const stage = await mkdtemp(join(tmpdir(), "hypersend-web-"));
      try {
        const paths: string[] = [];
        for (const f of files) {
          const p = join(stage, f.name.replaceAll("/", "_"));
          await writeFile(p, f.data);
          paths.push(p);
        }
        const result = await sendFiles(paths, { label: "wifi", host, port }, {
          streams: opts.streams ?? 2,
          onProgress: (p: Progress) => {
            lastTransfer = {
              fileName: p.fileName,
              bytesDone: p.bytesDone,
              bytesTotal: p.bytesTotal,
              mibsPerSec: p.mibsPerSec,
              perPath: p.perPath,
            };
            broadcast();
          },
        });
        lastTransfer = null;
        broadcast();
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true, files: result.files, skipped: result.skipped, bytes: result.bytes }));
      } catch (err) {
        lastTransfer = null;
        broadcast();
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }));
      } finally {
        await rm(stage, { recursive: true, force: true });
      }
      return;
    }

    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  }

  // Bind the page: try the default port, fall back to ephemeral.
  let uiPort = opts.uiPort ?? 44020;
  try {
    await once(http.listen(uiPort, "0.0.0.0"), "listening");
  } catch {
    uiPort = 0;
    await once(http.listen(uiPort, "0.0.0.0"), "listening");
  }
  const addr = http.address();
  const realPort = addr && typeof addr === "object" ? addr.port : uiPort;

  return {
    url: `http://localhost:${realPort}`,
    controlPort: rx.address.port,
    stop: async () => {
      watcher.stop();
      beacon.stop();
      rx.stop();
      for (const res of clients) res.end();
      clients.clear();
      await new Promise<void>((res) => http.close(() => res()));
    },
  };
}
