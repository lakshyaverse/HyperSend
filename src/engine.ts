/**
 * HyperSend engine v2 — chunked multipath data plane.
 *
 * Concept: a file is a list of fixed-size chunks. The sender owns a queue of
 * chunk offsets and a pool of data-plane sockets — one pool per PATH (Wi-Fi,
 * USB tether, another NIC…). Every worker loops: take next offset, read that
 * span from disk, ship it down its socket with a 13-byte header. Fast paths
 * pull more chunks from the shared queue; slow ones don't hold anyone back.
 * The receiver reassembles chunks from ANY socket by offset (pwrite semantics),
 * so path count and chunk order are irrelevant to correctness.
 *
 * Integrity: final SHA-256 over the whole file, mandatory, on the receiver.
 * Resume: offer-response carries the on-disk size; sender schedules chunks
 * beyond that offset only.
 */

import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { mkdir, open, stat, type FileHandle } from "node:fs/promises";
import { once } from "node:events";
import { connect, createServer, type Server, type Socket } from "node:net";
import {
  CHUNK_SIZE,
  ControlChannel,
  DEFAULT_PORT,
  PROTOCOL_VERSION,
  readChunkHeader,
  sanitizeRelativePath,
  writeChunk,
  writeControl,
  type BatchDoneMessage,
  type ControlMessage,
  type FileDoneMessage,
  type FileSentMessage,
  type HelloMessage,
  type OfferMessage,
  type OfferResponseMessage,
  type ReadyMessage,
} from "./protocol.js";
import { connectOpts, tuneSocket } from "./tuning.js";
import { newTransferId, sha256File } from "./hash.js";

// ── Shared types ─────────────────────────────────────────────────────────────

export type PathStats = { label: string; bytes: number; chunks: number };

export type Progress = {
  fileIndex: number;
  totalFiles: number;
  fileName: string;
  bytesDone: number;
  bytesTotal: number;
  mibsPerSec: number;
  perPath: PathStats[];
};

export type ProgressCallback = (p: Progress) => void;

export type EngineOptions = {
  port?: number;
  /**
   * Receiver-only: fixed port for the data plane (0 = ephemeral). A fixed
   * port is what makes a tunnel possible — e.g. `adb forward tcp:44012
   * tcp:44012` gives the USB cable its own path into the receiver.
   */
  dataPort?: number;
  /** Parallel sockets PER PATH. */
  streams?: number;
  onProgress?: ProgressCallback;
  /** Receiver-only: return false to decline an incoming file. */
  confirmOffer?: (offer: { path: string; size: number }) => Promise<boolean> | boolean;
};

export type SendTarget = {
  /** Logical label for progress reporting, e.g. "wifi" or "usb-tether". */
  label: string;
  /** IP of the RECEIVER reachable via this path. */
  host: string;
  /** Control port (only used for the primary target). */
  port?: number;
  /**
   * Data-plane port for THIS path. Defaults to the port the receiver
   * advertised. Set it when the path is a tunnel with a fixed port, e.g.
   * 127.0.0.1:44012 through `adb forward` (USB cable).
   */
  dataPort?: number;
};

type Deferred<T> = { promise: Promise<T>; resolve: (v: T) => void; reject: (e: unknown) => void };

function deferred<T>(): Deferred<T> {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function nowMs(): number {
  return Number(process.hrtime.bigint() / 1_000_000n);
}

/** Chunks allowed queued for write at once (receiver side). */
const RECEIVER_MAX_PENDING = 64;

// ── Receiver ─────────────────────────────────────────────────────────────────

export type ReceivedFile = { path: string; size: number; sha256: string };

export type Receiver = {
  done: Promise<ReceivedFile[]>;
  address: { port: number };
  stop: () => void;
};

export async function startReceiver(destDir: string, opts: EngineOptions = {}): Promise<Receiver> {
  const absDest = resolve(destDir);
  await mkdir(absDest, { recursive: true });

  const received: ReceivedFile[] = [];
  const finished = deferred<ReceivedFile[]>();
  let batchSeen = false;

  const server: Server = createServer((controlSock) => {
    runSession(controlSock).catch((err) => {
      console.error("[hypersend] session failed:", err instanceof Error ? err.message : err);
      controlSock.destroy();
      if (!batchSeen) finished.reject(err);
    });
  });

  const listenPort = opts.port ?? DEFAULT_PORT;
  await once(server.listen(listenPort, "0.0.0.0"), "listening");

  return {
    done: finished.promise,
    get address() {
      const addr = server.address();
      const port = addr && typeof addr === "object" ? addr.port : listenPort;
      return { port };
    },
    stop: () => {
      server.close();
      if (!batchSeen) finished.reject(new Error("receiver stopped"));
    },
  };

  type ActiveFile = {
    transferId: string;
    absPath: string;
    totalSha: string;
    fh: FileHandle;
    totalSize: number;
    startOffset: number;
    receivedSet: Set<number>; // chunk indices queued for write
    chunkCount: number;
    queue: Array<{ offset: number; payload: Buffer }>;
    pendingWrites: number;
    idleWakers: Array<() => void>;
    drained: Promise<void>;
    markDrained: () => void;
    failed: Error | null;
    startedAt: number;
  };

  async function runSession(controlSock: Socket): Promise<void> {
    tuneSocket(controlSock, "control");
    let dataServer: Server | null = null;

    // Per-session on purpose (previously engine-wide): two simultaneous
    // senders used to share one `active` file and one socket set, so session
    // A's chunks fed session B's file and one cleanup() destroyed the other
    // session's sockets. Session state must die with the session.
    const sessionDataSockets = new Set<Socket>();
    let active: ActiveFile | null = null;
    let openDataSockets = 0;

    const cleanup = () => {
      try {
        dataServer?.close();
      } catch {
        // ignore
      }
      for (const s of sessionDataSockets) s.destroy();
      sessionDataSockets.clear();
      controlSock.destroy();
    };

    try {
      await new Promise<void>((resolveSession, rejectSession) => {
        const channel = new ControlChannel(controlSock, (msg) => {
          void onMessage(msg).catch((err) => {
            const message = err instanceof Error ? err.message : String(err);
            void writeControl(controlSock, { type: "error", message }).catch(() => {});
            rejectSession(err);
          });
        });
        void channel;

        // A sender that walks away mid-batch must end the session: without
        // this the session promise never settles, the data listener leaks,
        // and a fixed --data-port can never be rebound by the next sender.
        // After a normal batch-done this is a no-op (already resolved).
        controlSock.once("close", () => {
          cleanup();
          rejectSession(new Error("sender closed the control channel"));
        });

        function bumpIdle(): void {
          const wake = active?.idleWakers.shift();
          if (wake) wake();
        }

        async function onMessage(msg: ControlMessage): Promise<void> {
          switch (msg.type) {
            case "hello": {
              if (msg.version !== PROTOCOL_VERSION) {
                throw new Error(`protocol mismatch: peer v${msg.version}, us v${PROTOCOL_VERSION}`);
              }
              dataServer = createServer((dataSock) => {
                tuneSocket(dataSock, "data");
                sessionDataSockets.add(dataSock);
                dataSock.once("close", () => sessionDataSockets.delete(dataSock));
                openDataSockets++;
                void ingestConnection(dataSock)
                  .catch(() => dataSock.destroy())
                  .finally(() => {
                    openDataSockets--;
                    bumpIdle();
                  });
              });
              await once(dataServer.listen(opts.dataPort ?? 0, "0.0.0.0"), "listening");
              const addr = dataServer.address();
              if (addr === null || typeof addr === "string") throw new Error("dataplane bind failed");
              const ready: ReadyMessage = {
                type: "ready",
                name: "hypersend",
                dataPort: addr.port,
                chunkSize: CHUNK_SIZE,
              };
              await writeControl(controlSock, ready);
              return;
            }
            case "offer":
              await handleOffer(msg);
              return;
            case "file-sent": {
              // Sender: all scheduled chunks are in flight/delivered. Wait for
              // the write pump to land every byte, then verify.
              const f = active;
              if (!f || f.transferId !== msg.transferId) return;
              await waitDrained(f);
              await finishFile(f);
              return;
            }
            case "batch-done":
              batchSeen = true;
              resolveSession();
              finished.resolve(received.slice());
              return;
            case "error":
              throw new Error(`peer error: ${msg.message}`);
            default:
              return;
          }
        }

        async function handleOffer(offer: OfferMessage): Promise<void> {
          const safePath = sanitizeRelativePath(offer.path);
          const absPath = join(absDest, safePath);
          await mkdir(dirname(absPath), { recursive: true });

          let offset = 0;
          try {
            const st = await stat(absPath);
            if (st.isFile() && st.size > 0 && st.size <= offer.size) {
              if (st.size === offer.size) {
                const existing = await sha256File(absPath);
                if (existing === offer.sha256) {
                  received.push({ path: absPath, size: offer.size, sha256: offer.sha256 });
                  await writeControl(controlSock, {
                    type: "offer-response",
                    transferId: offer.transferId,
                    accept: true,
                    offset: offer.size,
                  } satisfies OfferResponseMessage);
                  await writeControl(controlSock, {
                    type: "file-done",
                    transferId: offer.transferId,
                    ok: true,
                  });
                  return;
                }
                offset = 0;
              } else {
                offset = st.size; // optimistic resume; final hash verifies
              }
            }
          } catch {
            offset = 0;
          }

          const accepted = opts.confirmOffer
            ? await opts.confirmOffer({ path: safePath, size: offer.size })
            : true;
          if (!accepted) {
            await writeControl(controlSock, {
              type: "offer-response",
              transferId: offer.transferId,
              accept: false,
              reason: "declined by receiver",
            } satisfies OfferResponseMessage);
            return;
          }

          await writeControl(controlSock, {
            type: "offer-response",
            transferId: offer.transferId,
            accept: true,
            offset,
          } satisfies OfferResponseMessage);

          if (offer.size > offset) {
            await activateFile(absPath, offer, offset);
          } else if (offer.size === 0) {
            const fh = await open(absPath, "w");
            await fh.close();
          }
          // File completion (hash + file-done) happens on "file-sent" or, for
          // zero-byte/no-op cases, right here:
          if (offer.size <= offset) {
            const hash = await sha256File(absPath);
            if (hash !== offer.sha256) {
              const { rm } = await import("node:fs/promises");
              await rm(absPath, { force: true });
              await writeControl(controlSock, {
              type: "file-done",
              transferId: offer.transferId,
              ok: false,
              error: "sha256 mismatch — file discarded (a corrupt resume prefix is the usual cause; the next attempt starts from zero)",
            });
            return;
            }
            received.push({ path: absPath, size: offer.size, sha256: hash });
            await writeControl(controlSock, {
              type: "file-done",
              transferId: offer.transferId,
              ok: true,
            });
          }
        }        function makeActive(offer: OfferMessage, absPath: string, startOffset: number, fh: FileHandle): ActiveFile {
          const chunkCount = Math.ceil((offer.size - startOffset) / CHUNK_SIZE);
          let drained!: () => void;
          const drainedPromise = new Promise<void>((res) => {
            drained = res;
          });
          return {
            transferId: offer.transferId,
            absPath,
            totalSha: offer.sha256,
            fh,
            totalSize: offer.size,
            startOffset,
            receivedSet: new Set(),
            chunkCount,
            queue: [],
            pendingWrites: 0,
            idleWakers: [],
            drained: drainedPromise,
            markDrained: drained,
            failed: null,
            startedAt: Date.now(),
          };
        }

        async function activateFile(absPath: string, offer: OfferMessage, startOffset: number): Promise<void> {
          const fh = await open(absPath, startOffset > 0 ? "r+" : "w");
          const f = makeActive(offer, absPath, startOffset, fh);
          active = f;

          // Serialised write pump: one writer, bounded queue, offset writes.
          void (async () => {
            try {
              for (;;) {
                const item = f.queue.shift();
                if (item) {
                  f.pendingWrites++;
                  try {
                    await f.fh.write(item.payload, 0, item.payload.length, item.offset);
                  } finally {
                    f.pendingWrites--;
                  }
                  bumpIdle();
                } else if (isFileComplete(f)) {
                  f.markDrained();
                  return;
                } else if (openDataSockets === 0 && f.queue.length === 0 && f.pendingWrites === 0) {
                  // All data sockets closed before the file completed — but a
                  // sender that dials lazily has NO sockets yet when the offer
                  // lands. Only declare the streams dead once some chunk
                  // arrived (and the sockets are truly gone) or the grace
                  // window expired — the same 1.5 s allowance the Swift and
                  // Kotlin receivers give a sender before giving up.
                  if (f.receivedSet.size > 0 || Date.now() - f.startedAt > 1_500) {
                    f.failed = new Error(
                      `data streams ended early: ${f.receivedSet.size}/${f.chunkCount} chunks`,
                    );
                    f.markDrained();
                    return;
                  }
                  // Lazy-dial window: re-check shortly, or as soon as a chunk
                  // or socket event wakes us.
                  await new Promise<void>((res) => {
                    const wake = () => {
                      clearTimeout(timer);
                      const i = f.idleWakers.indexOf(wake);
                      if (i !== -1) f.idleWakers.splice(i, 1);
                      res();
                    };
                    const timer = setTimeout(wake, 200);
                    f.idleWakers.push(wake);
                  });
                } else {
                  await new Promise<void>((res) => f.idleWakers.push(res));
                }
              }
            } catch (err) {
              f.failed = err instanceof Error ? err : new Error(String(err));
              f.markDrained();
            }
          })();
        }

        function isFileComplete(f: ActiveFile): boolean {
          return f.receivedSet.size === f.chunkCount && f.pendingWrites === 0 && f.queue.length === 0;
        }

        async function waitDrained(f: ActiveFile): Promise<void> {
          await f.drained;
          if (f.failed) throw f.failed;
        }

        async function finishFile(f: ActiveFile): Promise<void> {
          const { rm } = await import("node:fs/promises");
          const hash = await sha256File(f.absPath);
          if (hash !== f.totalSha) {
            await rm(f.absPath, { force: true });
            await writeControl(controlSock, {
            type: "file-done",
            transferId: f.transferId,
            ok: false,
            error: "sha256 mismatch — file discarded (a corrupt resume prefix is the usual cause; the next attempt starts from zero)",
          });
          } else {
            received.push({ path: f.absPath, size: f.totalSize, sha256: hash });
            await writeControl(controlSock, {
              type: "file-done",
              transferId: f.transferId,
              ok: true,
            });
          }
          active = null;
          await f.fh.close().catch(() => {});
        }

        async function ingestConnection(sock: Socket): Promise<void> {
          const read = readExactFactory(sock);
          for (;;) {
            const head = await readChunkHeader(read);
            if (!head) break;
            const payload = await readExactN(read, head.payloadBytes);
            const f = active;
            if (!f) throw new Error("chunk arrived with no active file");
            const idx = Math.floor(Number(head.offset) / CHUNK_SIZE);
            while (f.queue.length + f.pendingWrites >= RECEIVER_MAX_PENDING) {
              await new Promise<void>((res) => f.idleWakers.push(res));
            }
            f.receivedSet.add(idx);
            f.queue.push({ offset: Number(head.offset), payload });
            bumpIdle();
          }
        }
      }).catch((err) => {
        cleanup();
        throw err;
      });
    } finally {
      cleanup();
    }
  }
}

function readExactFactory(sock: Socket): (n: number) => Promise<Buffer | null> {
  let buf = Buffer.alloc(0);
  let eof = false;
  return async (n: number) => {
    while (buf.length < n) {
      if (eof) return null;
      const chunk: Buffer | null = await new Promise((res) => {
        const ondata = (c: Buffer) => {
          cleanup();
          res(c);
        };
        const onclose = () => {
          cleanup();
          res(null);
        };
        const cleanup = () => {
          sock.off("data", ondata);
          sock.off("close", onclose);
        };
        sock.once("data", ondata);
        sock.once("close", onclose);
      });
      if (!chunk) {
        eof = true;
        break;
      }
      buf = buf.length === 0 ? Buffer.from(chunk) : Buffer.concat([buf, chunk]);
    }
    if (buf.length < n) return null;
    const out = buf.subarray(0, n);
    buf = buf.subarray(n);
    return out;
  };
}

async function readExactN(read: (n: number) => Promise<Buffer | null>, n: number): Promise<Buffer> {
  const out = await read(n);
  if (!out || out.length < n) throw new Error("chunk payload cut short");
  return out;
}

// ── Path discovery helpers ───────────────────────────────────────────────────────────

/** Sanitise sender paths into wire-safe relative paths. */
export function toRelPath(absPath: string, baseDir?: string): string {
  const abs = resolve(absPath);
  if (baseDir) {
    const rel = relative(resolve(baseDir), abs);
    if (rel && !rel.startsWith("..") && !isAbsolute(rel)) return rel.split(sep).join("/");
  }
  return basename(abs);
}

// ── Sender ───────────────────────────────────────────────────────────────

export type SendResult = {
  files: number;
  /** Offers the receiver declined; reported, not fatal. */
  skipped: number;
  bytes: number;
  elapsedMs: number;
  mibsPerSec: number;
  perPath: PathStats[];
};

export async function sendFiles(
  paths: string[],
  targets: SendTarget | SendTarget[],
  opts: EngineOptions = {},
): Promise<SendResult> {
  const targetList = Array.isArray(targets) ? targets : [targets];
  if (targetList.length === 0) throw new Error("no targets");
  const streams = Math.max(1, opts.streams ?? 2);
  const started = nowMs();

  type Job = { absPath: string; relPath: string; size: number; hash: string };
  const jobs: Job[] = [];
  for (const p of paths) {
    const abs = resolve(p);
    const st = await stat(abs);
    if (!st.isFile()) throw new Error(`not a regular file: ${abs}`);
    jobs.push({ absPath: abs, relPath: toRelPath(abs), size: st.size, hash: "" });
  }

  // Control runs over the FIRST target only; all targets must be IPs of the
  // SAME receiver (different links to one machine).
  const primary = targetList[0]!;
  const control = connect(connectOpts(primary.host, primary.port ?? DEFAULT_PORT));
  tuneSocket(control, "control");
  await once(control, "connect");

  const inbox: ControlMessage[] = [];
  const wakeWaiters: Array<() => void> = [];
  const notify = () => {
    for (const w of wakeWaiters.splice(0)) w();
  };

  let readyMsg: ReadyMessage | null = null;
  const channel = new ControlChannel(control, (msg) => {
    if (msg.type === "ready" && readyMsg === null) readyMsg = msg;
    inbox.push(msg);
    notify();
  });
  void channel;

  const hello: HelloMessage = {
    type: "hello",
    version: PROTOCOL_VERSION,
    name: "hypersend",
    chunkSize: CHUNK_SIZE,
  };
  await writeControl(control, hello);

  const ready = await new Promise<ReadyMessage>((res, rej) => {
    // Self-removing waiter: unlike the old closure dropped into wakeWaiters
    // and abandoned on timeout, this one always cleans up after itself —
    // notify() splices the array before firing, so a fired waiter's removal
    // below is a harmless no-op.
    const check = () => {
      if (!readyMsg) return false;
      const i = wakeWaiters.indexOf(check);
      if (i !== -1) wakeWaiters.splice(i, 1);
      clearTimeout(timer);
      res(readyMsg);
      return true;
    };
    const timer = setTimeout(() => {
      const i = wakeWaiters.indexOf(check);
      if (i !== -1) wakeWaiters.splice(i, 1);
      rej(new Error("receiver did not answer hello (timeout)"));
    }, 15_000);
    if (!check()) wakeWaiters.push(check);
  });

  const dataPort = ready.dataPort;
  if (typeof dataPort !== "number") throw new Error("receiver did not advertise a data port");

  // One socket pool per path; every socket carries chunks independently.
  type PathCtx = { label: string; host: string; dataPort: number; sockets: Socket[]; bytes: number; chunks: number };
  const pathCtxs: PathCtx[] = targetList.map((t) => ({
    label: t.label,
    host: t.host,
    dataPort: t.dataPort ?? dataPort,
    sockets: [],
    bytes: 0,
    chunks: 0,
  }));

  /** One awaited dial (3 s budget, like the Swift sender). */
  const dial = (ctx: PathCtx): Promise<Socket> =>
    new Promise((res, rej) => {
      const s = connect(connectOpts(ctx.host, ctx.dataPort));
      tuneSocket(s, `data:${ctx.label}`);
      const timer = setTimeout(() => finish(new Error("connect timed out")), 3_000);
      const finish = (err?: Error) => {
        clearTimeout(timer);
        s.off("connect", onConnect);
        s.off("error", onError);
        if (err) {
          s.destroy();
          rej(err);
        } else {
          ctx.sockets.push(s);
          s.once("close", () => {
            const i = ctx.sockets.indexOf(s);
            if (i !== -1) ctx.sockets.splice(i, 1);
          });
          res(s);
        }
      };
      const onConnect = () => finish();
      const onError = (err: Error) => finish(err);
      s.once("connect", onConnect);
      s.once("error", onError);
    });

  // Open every lane up front, but a lane that will not open must not kill the
  // transfer: losing the cable should just mean a slower send. This is the
  // same contract the Swift and Kotlin senders already honour (per-socket
  // catch, 3 s dial budget); the Node engine used to abort the whole batch
  // the moment one path refused a connection.
  for (const ctx of pathCtxs) {
    for (let i = 0; i < streams; i++) {
      try {
        await dial(ctx);
      } catch (err) {
        console.error(
          `[hypersend] lane ${ctx.label} on :${ctx.dataPort} unavailable — ${err instanceof Error ? err.message : err}`,
        );
        break;
      }
    }
  }
  if (pathCtxs.every((c) => c.sockets.length === 0)) {
    throw new Error("no data lanes could be opened");
  }

  // Prefetch window: hash file N+k while file N streams.
  const hashJobs: Array<Promise<void>> = [];
  const hashConcurrency = Math.min(4, Math.max(1, streams));
  const startHash = (i: number): void => {
    if (i >= jobs.length || hashJobs[i]) return;
    const job = jobs[i]!;
    hashJobs[i] = sha256File(job.absPath).then((h) => {
      job.hash = h;
    });
  };
  for (let i = 0; i < hashConcurrency; i++) startHash(i);

  let filesDone = 0;
  let skipped = 0;
  let bytesDone = 0;
  let lastTick = nowMs();
  let lastBytes = 0;
  const totalBytes = jobs.reduce((acc, j) => acc + j.size, 0);
  // Per-file progress accounting: bytesDone is batch-cumulative, so the
  // callback subtracts everything already finished to report THIS file's own
  // progress (the old code reported cumulative bytes with per-file
  // fileIndex/fileName, which reads as nonsense for every file after the
  // first).
  let bytesDoneBeforeFile = 0;
  let currentJobSize = 0;

  for (let idx = 0; idx < jobs.length; idx++) {
    const job = jobs[idx]!;
    await hashJobs[idx]!;
    startHash(idx + hashConcurrency);

    const transferId = newTransferId();
    const offer: OfferMessage = {
      type: "offer",
      transferId,
      path: job.relPath,
      size: job.size,
      sha256: job.hash,
    };
    await writeControl(control, offer);

    const resp = (await waitFor(
      (m) => m.type === "offer-response" && m.transferId === transferId,
      15_000,
    )) as OfferResponseMessage;
    if (!resp.accept) {
      // Decline is a decision, not a failure: log it, keep the batch moving.
      // (The Swift sender used to abort the whole batch here; it now skips
      // too, so all three implementations agree on this semantic.)
      console.error(`[hypersend] receiver declined ${job.relPath}: ${resp.reason ?? "no reason"}`);
      skipped++;
      bytesDoneBeforeFile = bytesDone;
      continue;
    }
    const startOffset = Math.max(0, Math.min(resp.offset ?? 0, job.size));

    if (job.size > startOffset) {
      bytesDoneBeforeFile = bytesDone;
      currentJobSize = job.size;
      await pumpChunks(job, startOffset, pathCtxs, () => {
        const msg: FileSentMessage = { type: "file-sent", transferId };
        return writeControl(control, msg);
      });
    } else {
      bytesDoneBeforeFile = bytesDone;
      currentJobSize = job.size;
      await writeControl(control, { type: "file-sent", transferId } as FileSentMessage);
    }

    const done = (await waitFor(
      (m) => m.type === "file-done" && m.transferId === transferId,
      600_000,
    )) as FileDoneMessage;
    if (!done.ok) throw new Error(`receiver rejected ${job.relPath}: ${done.error ?? "verify failed"}`);
    filesDone++;
  }

  const elapsedMs = nowMs() - started;
  const batchDone: BatchDoneMessage = {
    type: "batch-done",
    files: filesDone,
    bytes: bytesDone,
    elapsedMs,
  };
  await writeControl(control, batchDone);
  control.end();
  await once(control, "close").catch(() => {});

  // Tear down pooled data sockets so the process can exit cleanly.
  for (const p of pathCtxs) {
    for (const s of p.sockets.splice(0)) s.destroy();
  }

  return {
    files: filesDone,
    skipped,
    bytes: bytesDone,
    elapsedMs,
    mibsPerSec: elapsedMs > 0 ? bytesDone / (1024 * 1024) / (elapsedMs / 1000) : 0,
    perPath: pathCtxs.map((p) => ({ label: p.label, bytes: p.bytes, chunks: p.chunks })),
  };

  /**
   * Self-balancing chunk scheduler: N workers over the shared offset queue.
   * Fast sockets pull more chunks; a stalled socket just stops being fed.
   * Every worker owns one socket exclusively — two workers sharing a socket
   * would interleave header+payload writes and corrupt the framing.
   */
  async function pumpChunks(
    job: { absPath: string; relPath: string; size: number },
    startOffset: number,
    paths: PathCtx[],
    onAllQueued: () => Promise<void>,
  ): Promise<void> {
    let nextOffset = startOffset;
    const allWorkers: Array<Promise<void>> = [];
    // One shared handle for positional reads: no per-chunk stream setup cost
    // (150+ createReadStream calls per 300 MB otherwise) and safe for
    // concurrent readers because reads are position-based.
    const { open } = await import("node:fs/promises");
    const fh = await open(job.absPath, "r");

    const worker = async (ctx: PathCtx, sock: Socket): Promise<void> => {
      for (;;) {
        const offset = nextOffset;
        if (offset >= job.size) return;
        nextOffset = offset + CHUNK_SIZE;
        const len = Math.min(CHUNK_SIZE, job.size - offset);
        const payload = await readSpan(fh, offset, len);
        await writeChunk(sock, payload, offset);
        ctx.bytes += payload.length;
        ctx.chunks++;
        bytesDone += payload.length;
        maybeProgress(job.relPath, paths);
      }
    };

    for (const ctx of paths) {
      for (const s of [...ctx.sockets]) {
        allWorkers.push(worker(ctx, s));
      }
    }
    try {
      await Promise.all(allWorkers);
    } finally {
      await fh.close().catch(() => {});
    }
    await onAllQueued();
    // Boundary tick, unthrottled: a file faster than the 250 ms progress
    // window (anything small over loopback) otherwise reports nothing at all
    // — the same force-emit the Swift sender does at end of file.
    maybeProgress(job.relPath, paths, true);
  }

  /** Positional read of exactly `len` bytes (short reads are retried). */
  async function readSpan(fh: FileHandle, start: number, len: number): Promise<Buffer> {
    const buf = Buffer.allocUnsafe(len);
    let got = 0;
    while (got < len) {
      const { bytesRead } = await fh.read(buf, got, len - got, start + got);
      if (bytesRead === 0) throw new Error(`unexpected EOF at ${start + got}`);
      got += bytesRead;
    }
    return buf;
  }

  function maybeProgress(fileName: string, paths: PathCtx[], force = false): void {
    const t = nowMs();
    if ((force || t - lastTick >= 250) && opts.onProgress) {
      opts.onProgress({
        fileIndex: filesDone,
        totalFiles: jobs.length,
        fileName,
        bytesDone: bytesDone - bytesDoneBeforeFile,
        bytesTotal: currentJobSize,
        mibsPerSec: (bytesDone - lastBytes) / (1024 * 1024) / ((t - lastTick) / 1000),
        perPath: paths.map((p) => ({ label: p.label, bytes: p.bytes, chunks: p.chunks })),
      });
      lastTick = t;
      lastBytes = bytesDone;
    }
  }

  function waitFor(pred: (m: ControlMessage) => boolean, timeoutMs: number): Promise<ControlMessage> {
    return new Promise((res, rej) => {
      const idx = inbox.findIndex(pred);
      if (idx !== -1) {
        const [msg] = inbox.splice(idx, 1);
        res(msg!);
        return;
      }
      const timer = setTimeout(() => {
        const i = wakeWaiters.indexOf(wake);
        if (i !== -1) wakeWaiters.splice(i, 1);
        rej(new Error("timed out waiting for control message"));
      }, timeoutMs);
      const wake = () => {
        const i = inbox.findIndex(pred);
        if (i !== -1) {
          const [msg] = inbox.splice(i, 1);
          clearTimeout(timer);
          res(msg!);
        }
      };
      wakeWaiters.push(wake);
    });
  }
}
