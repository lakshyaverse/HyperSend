/**
 * Zero-config discovery — a tiny UDP beacon instead of mDNS/BLE. Not faster
 * for the transfer itself (discovery doesn't touch throughput), but it removes
 * mDNS daemon flakiness and works identically on macOS, Linux and Android.
 *
 * Receiver broadcasts "I'm here, connect at :PORT". Sender listens and picks
 * the first (or matching) peer. Traffic is plaintext because it leaks nothing
 * but a name and a port on the local network.
 *
 * Hardened: every socket callback is guarded so a dead radio, a closed socket
 * or an EACCES broadcast can never take the receiver process down.
 */

import { createSocket, type RemoteInfo } from "node:dgram";
import { once } from "node:events";

export const DISCOVERY_PORT = 44011;
const MAGIC = "hypersend-beacon-v1";
const BEACON_INTERVAL_MS = 500;

export type DiscoveredPeer = { host: string; port: number; name: string };

type BeaconMsg = { magic: string; port: number; name: string };

function encodeBeacon(msg: BeaconMsg): Buffer {
  return Buffer.from(JSON.stringify(msg), "utf8");
}

function decodeBeacon(buf: Buffer): BeaconMsg | null {
  try {
    const parsed = JSON.parse(buf.toString("utf8")) as Partial<BeaconMsg>;
    if (parsed.magic !== MAGIC || typeof parsed.port !== "number") return null;
    if (!Number.isInteger(parsed.port) || parsed.port < 1 || parsed.port > 65535) return null;
    return { magic: MAGIC, port: parsed.port, name: typeof parsed.name === "string" ? parsed.name : "unknown" };
  } catch {
    return null;
  }
}

/** Receiver side: broadcast our presence + control port until stopped. */
export function startBeacon(controlPort: number, name: string): { stop: () => void } {
  const payload = encodeBeacon({ magic: MAGIC, port: controlPort, name });
  let stopped = false;
  let timer: NodeJS.Timeout | null = null;
  let sock: ReturnType<typeof createSocket> | null = null;

  const closeSafely = (): void => {
    stopped = true;
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    if (sock) {
      try {
        sock.close();
      } catch {
        // already closed
      }
      sock = null;
    }
  };

  try {
    sock = createSocket({ type: "udp4", reuseAddr: true });
    sock.on("error", (err) => {
      // Never let discovery errors kill the receiver — it can still be used
      // with explicit --to <host>. Log quietly and disable the beacon.
      console.error(`[hypersend] beacon disabled: ${err.message}`);
      closeSafely();
    });
    sock.bind(DISCOVERY_PORT, () => {
      sock?.setBroadcast(true);
    });

    timer = setInterval(() => {
      if (stopped || !sock) return;
      // Broadcast for the LAN; loopback for same-machine senders (tests, demos).
      for (const target of ["255.255.255.255", "127.0.0.1"]) {
        if (stopped || !sock) return;
        sock.send(payload, DISCOVERY_PORT, target, (err) => {
          if (err && !stopped) {
            console.error(`[hypersend] beacon send failed (${target}): ${err.message}`);
          }
        });
      }
    }, BEACON_INTERVAL_MS);
  } catch (err) {
    console.error(`[hypersend] beacon unavailable: ${err instanceof Error ? err.message : err}`);
    closeSafely();
  }

  return { stop: closeSafely };
}

/** Sender side: listen for beacons, resolve the first matching peer. */
export async function discoverPeer(timeoutMs = 5_000, wantName?: string): Promise<DiscoveredPeer> {
  const sock = createSocket({ type: "udp4", reuseAddr: true });
  const found: DiscoveredPeer[] = [];

  sock.on("message", (buf: Buffer, rinfo: RemoteInfo) => {
    const msg = decodeBeacon(buf);
    if (!msg) return;
    if (wantName && msg.name !== wantName) return;
    if (!found.some((p) => p.host === rinfo.address && p.port === msg.port)) {
      found.push({ host: rinfo.address, port: msg.port, name: msg.name });
    }
  });
  // Discovery must never crash the sender either.
  sock.on("error", () => {
    /* handled by timeout below */
  });

  try {
    // A failed bind surfaces as an 'error' EVENT, not a throw, so diagnosing
    // it in a catch block — as this code once pretended to — never ran. The
    // port being taken almost always means a receiver is beaconing RIGHT
    // HERE and its loopback copy (127.0.0.1) is the peer we want; say that.
    const onBindError = (err: Error): void => {
      console.error(
        `[hypersend] could not bind UDP ${DISCOVERY_PORT} (${err.message}) — ` +
          `a receiver running on this machine still resolves via its loopback beacons; otherwise pass --to <ip>`,
      );
    };
    sock.once("error", onBindError);
    sock.bind(DISCOVERY_PORT);
    // Never let a socket that failed to open hang discovery: race the
    // listening event against a short budget and move on either way.
    await Promise.race([
      once(sock, "listening").catch(() => {}),
      new Promise((res) => setTimeout(res, 1_000)),
    ]);
    sock.off("error", onBindError);
  } catch {
    // Synchronous bind failure (invalid args); the error event covers the rest.
  }

  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const peer = found[0];
    if (peer) {
      try {
        sock.close();
      } catch {
        // ignore
      }
      return peer;
    }
    if (Date.now() > deadline) {
      try {
        sock.close();
      } catch {
        // ignore
      }
      throw new Error(`no peers found within ${timeoutMs} ms`);
    }
    await new Promise((r) => setTimeout(r, 100));
  }
}
