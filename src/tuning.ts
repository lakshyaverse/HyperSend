/**
 * Socket tuning. The Gemini pitch overstates this ("root sysctl! 16MB buffers!")
 * — on a LAN the bandwidth-delay product is ~250 KB per Gbps at 1 ms RTT, so a
 * few MB of socket buffer is plenty. What genuinely matters:
 *   - TCP_NODELAY on every socket (no Nagle-induced latency on control frames),
 *   - keepalive for long transfers,
 *   - buffers comfortably above the BDP so the window never clamps.
 * Node sets these per-socket via setsockopt — no root, no sysctl, portable.
 */

import type { Socket } from "node:net";

/** 8 MiB — far above any plausible LAN BDP; OS clamps down to its own max. */
export const SOCKET_BUFFER_BYTES = 8 * 1024 * 1024;

export function tuneSocket(socket: Socket, label: string): void {
  socket.setNoDelay(true);
  socket.setKeepAlive(true, 5_000);
  // Best-effort: some platforms ignore or clamp these; that's fine.
  try {
    (socket as Socket & { setRecvBufferSize?(n: number): void }).setRecvBufferSize?.(SOCKET_BUFFER_BYTES);
    (socket as Socket & { setSendBufferSize?(n: number): void }).setSendBufferSize?.(SOCKET_BUFFER_BYTES);
  } catch {
    // ignored — tuning is opportunistic
  }
  socket.on("error", (err) => {
    console.error(`[hypersend] ${label} socket error:`, err.message);
  });
}

export function connectOpts(host: string, port: number): { host: string; port: number } {
  // Tuning (nodelay, keepalive, buffers) is applied post-connect by tuneSocket.
  return { host, port };
}
