/**
 * HyperSend wire protocol v2 — length-prefixed JSON control channel plus a
 * chunked, multipath data plane.
 *
 * v1 (retained concepts): control frames are [4-byte BE length][JSON]. File
 * bytes streamed raw per-file on one connection.
 *
 * v2 changes: file bytes are chunked. The SENDER decides which transport a
 * chunk rides on; every data connection carries a tiny 9-byte header per
 * chunk, so the receiver can reassemble chunks that arrive from any pipe:
 *   [4-byte BE chunk length][1-byte flags][8-byte BE chunk offset][payload]
 * The receiver aggregates payload bytes at their offsets, so transfers are
 * order-independent across N parallel sockets on N paths.
 */

import { once as onceEvent } from "node:events";
import type { Socket } from "node:net";

export const PROTOCOL_VERSION = 2;

export const DEFAULT_PORT = 44010;

const LENGTH_PREFIX_BYTES = 4;
/** Refuse absurd control messages — this is a LAN protocol, not a REST API. */
export const MAX_CONTROL_MESSAGE_BYTES = 1 * 1024 * 1024;

/** Payload bytes per chunk on the data plane. */
export const CHUNK_SIZE = 2 * 1024 * 1024;

/** Data-plane chunk header: length(4) + flags(1) + offset(8). */
export const CHUNK_HEADER_BYTES = 13;
const FLAG_V2 = 0x01;

// ── Control message types ────────────────────────────────────────────────────

export type HelloMessage = {
  type: "hello";
  version: number;
  name: string;
  /** Preferred chunk size for this sender. */
  chunkSize: number;
};

export type ReadyMessage = {
  type: "ready";
  name: string;
  /** Ephemeral port of the receiver's data-plane listener. */
  dataPort: number;
  /** Acknowledged chunk size (receiver may clamp). */
  chunkSize: number;
};

export type OfferMessage = {
  type: "offer";
  transferId: string;
  path: string;
  size: number;
  sha256: string;
};

export type OfferResponseMessage = {
  type: "offer-response";
  transferId: string;
  accept: boolean;
  /** Bytes the receiver already has (resume offset), 0 when fresh. */
  offset?: number;
  reason?: string;
};

export type FileDoneMessage = {
  type: "file-done";
  transferId: string;
  ok: boolean;
  error?: string;
};

export type FileSentMessage = {
  type: "file-sent";
  transferId: string;
};

export type BatchDoneMessage = {
  type: "batch-done";
  files: number;
  bytes: number;
  elapsedMs: number;
};

export type ErrorMessage = {
  type: "error";
  message: string;
};

export type ControlMessage =
  | HelloMessage
  | ReadyMessage
  | OfferMessage
  | OfferResponseMessage
  | FileSentMessage
  | FileDoneMessage
  | BatchDoneMessage
  | ErrorMessage;

// ── Framing ──────────────────────────────────────────────────────────────────

/**
 * Wait until the socket drains, or fail fast if the peer goes away first.
 *
 * A plain `once(socket, "drain")` hangs forever when the peer vanishes
 * without an RST: Node emits "close" (or nothing at all until keepalive
 * gives up minutes later), never "error" — a Wi-Fi drop or a phone falling
 * asleep would wedge the writer on that await for good. Racing drain against
 * close/end/error turns the silent wedge into an ordinary socket error that
 * the lane-loss handling in the sender can retire.
 */
async function drainedOrClosed(socket: Socket): Promise<void> {
  if (socket.writableLength === 0) return;
  if (socket.destroyed || socket.writableEnded) {
    throw new Error("socket closed before drain — peer went away");
  }
  await new Promise<void>((resolve, reject) => {
    const done = (err?: Error) => {
      socket.off("drain", onDrain);
      socket.off("close", onClose);
      socket.off("end", onClose);
      socket.off("error", onError);
      if (err) reject(err);
      else resolve();
    };
    const onDrain = () => done();
    const onClose = () => done(new Error("socket closed before drain — peer went away"));
    const onError = (err: Error) => done(err);
    socket.once("drain", onDrain);
    socket.once("close", onClose);
    socket.once("end", onClose);
    socket.once("error", onError);
  });
}

/** Write one length-prefixed JSON message. Awaits drain to bound memory. */
export async function writeControl(socket: Socket, msg: ControlMessage): Promise<void> {
  const payload = Buffer.from(JSON.stringify(msg), "utf8");
  if (payload.length > MAX_CONTROL_MESSAGE_BYTES) {
    throw new Error(`control message too large: ${payload.length} bytes`);
  }
  const frame = Buffer.alloc(LENGTH_PREFIX_BYTES + payload.length);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, LENGTH_PREFIX_BYTES);
  if (!socket.write(frame)) {
    await drainedOrClosed(socket);
  }
}

/** Incremental length-prefixed JSON message parser for a readable socket. */
export class ControlChannel {
  private buffer = Buffer.alloc(0);

  constructor(
    private readonly socket: Socket,
    private readonly onMessage: (msg: ControlMessage) => void,
  ) {
    socket.on("data", (chunk: Buffer) => this.onData(chunk));
  }

  private onData(chunk: Buffer): void {
    this.buffer = this.buffer.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.buffer, chunk]);
    for (;;) {
      if (this.buffer.length < LENGTH_PREFIX_BYTES) return;
      const len = this.buffer.readUInt32BE(0);
      if (len > MAX_CONTROL_MESSAGE_BYTES) {
        this.socket.destroy(new Error(`framing violation: ${len} byte control message`));
        return;
      }
      if (this.buffer.length < LENGTH_PREFIX_BYTES + len) return;
      const body = this.buffer.subarray(LENGTH_PREFIX_BYTES, LENGTH_PREFIX_BYTES + len);
      this.buffer = this.buffer.subarray(LENGTH_PREFIX_BYTES + len);
      try {
        this.onMessage(JSON.parse(body.toString("utf8")) as ControlMessage);
      } catch (err) {
        this.socket.destroy(new Error(`bad control JSON: ${String(err)}`));
        return;
      }
    }
  }
}

/** Write one v2 chunk: header + payload. Awaits drain to bound memory. */
export async function writeChunk(
  socket: Socket,
  payload: Buffer,
  fileOffset: number,
): Promise<void> {
  const header = Buffer.allocUnsafe(CHUNK_HEADER_BYTES);
  header.writeUInt32BE(CHUNK_HEADER_BYTES - 4 + payload.length, 0);
  header.writeUInt8(FLAG_V2, 4);
  header.writeBigUInt64BE(BigInt(fileOffset), 5);
  socket.write(header);
  if (!socket.write(payload)) {
    await drainedOrClosed(socket);
  }
}

export type ChunkHeader = { payloadBytes: number; offset: bigint; flags: number };

/** Read one chunk header from a byte-accurate reader. Returns null on EOF. */
export async function readChunkHeader(read: (n: number) => Promise<Buffer | null>): Promise<ChunkHeader | null> {
  const head = await read(CHUNK_HEADER_BYTES);
  if (!head) return null;
  const len = head.readUInt32BE(0);
  if (len < CHUNK_HEADER_BYTES - 4 || len > 64 * 1024 * 1024) {
    throw new Error(`bad chunk length: ${len}`);
  }
  return {
    payloadBytes: len - (CHUNK_HEADER_BYTES - 4),
    flags: head.readUInt8(4),
    offset: head.readBigUInt64BE(5),
  };
}

// ── Path safety (receiver side) ──────────────────────────────────────────────

/**
 * Reject path traversal and absolute paths. Returns a normalised relative path
 * using forward slashes. This is the *only* place paths cross the wire, so it
 * is the only place sanitisation is needed.
 */
export function sanitizeRelativePath(input: string): string {
  if (typeof input !== "string" || input.length === 0 || input.length > 512) {
    throw new Error("invalid path");
  }
  const normalised = input.replaceAll("\\", "/");
  const parts = normalised.split("/");
  for (const part of parts) {
    if (part === "" || part === "." || part === ".." || part.includes("\0")) {
      throw new Error(`unsafe path segment: ${JSON.stringify(part)}`);
    }
  }
  const joined = parts.join("/");
  if (/^[a-zA-Z]:/.test(joined) || joined.startsWith("/")) {
    throw new Error("absolute paths not allowed");
  }
  return joined;
}
