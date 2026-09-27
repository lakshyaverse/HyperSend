#!/usr/bin/env node
/**
 * HyperSend CLI.
 *
 *   hypersend receive [destDir]          — be a receiver (beacon on by default)
 *   hypersend send <files...> [--to h]   — send files (auto-discovers receiver)
 *   hypersend bench [--size N]           — localhost throughput sanity test
 */

import { argv, exit, stdout } from "node:process";
import { hostname } from "node:os";
import { DEFAULT_PORT } from "./protocol.js";
import { DISCOVERY_PORT, discoverPeer, startBeacon } from "./discovery.js";
import { startReceiver, sendFiles, type Progress } from "./engine.js";

function usage(): never {
  stdout.write(
    [
      "hypersend — LAN file transfer",
      "",
      "  hypersend receive [destDir] [--port N] [--data-port N] [--streams N]",
      "  hypersend send <file...> [--to host] [--extra-path ip[:dataPort],...] [--streams N]",
      "",
      "  USB path (no driver needed): adb forward tcp:44012 tcp:44012",
      "    then: hypersend send <file> --to <wifi-ip> --extra-path 127.0.0.1:44012",
      "  hypersend bench [--size MB]",
      "",
      `Defaults: port ${DEFAULT_PORT} (control+data), discovery beacon on UDP ${DISCOVERY_PORT}.`,
    ].join("\n") + "\n",
  );
  exit(0);
}

function parseArgs(rest: string[]): { pos: string[]; flags: Map<string, string> } {
  const pos: string[] = [];
  const flags = new Map<string, string>();
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i]!;
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = rest[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        flags.set(key, next);
        i++;
      } else {
        flags.set(key, "true");
      }
    } else {
      pos.push(a);
    }
  }
  return { pos, flags };
}

function fmtBytes(n: number): string {
  if (n >= 1024 * 1024 * 1024) return `${(n / 1024 ** 3).toFixed(2)} GB`;
  if (n >= 1024 * 1024) return `${(n / 1024 ** 2).toFixed(2)} MB`;
  if (n >= 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${n} B`;
}

function renderProgress(p: Progress): void {
  const pct = p.bytesTotal > 0 ? Math.min(100, (p.bytesDone / p.bytesTotal) * 100) : 100;
  const bar = "=".repeat(Math.round(pct / 4)).padEnd(25, " ");
  const paths = p.perPath.map((pp) => `${pp.label} ${(pp.bytes / 1024 ** 2).toFixed(0)}MB`).join(" + ");
  stdout.write(
    `\r  [${bar}] ${pct.toFixed(1).padStart(5)}%  ${fmtBytes(p.bytesDone)} / ${fmtBytes(p.bytesTotal)}  ${p.mibsPerSec.toFixed(1).padStart(6)} MiB/s  [${paths}] ${p.fileName.slice(0, 28)}   `,
  );
}

async function main(): Promise<void> {
  const [cmd, ...rest] = argv.slice(2);
  if (!cmd || cmd === "help" || cmd === "--help") usage();
  const { pos, flags } = parseArgs(rest);

  const port = Number.parseInt(flags.get("port") ?? "", 10) || DEFAULT_PORT;
  const streams = Math.max(1, Number.parseInt(flags.get("streams") ?? "", 10) || 2);
  const dataPort = Number.parseInt(flags.get("data-port") ?? "", 10) || 0;

  switch (cmd) {
    case "receive": {
      const dest = pos[0] ?? "./received";
      const beacon = flags.get("no-beacon") !== "true";
      // The beacon name defaults to this machine's hostname, so a Linux or
      // Windows receiver announces itself as what it is instead of "macbook".
      const name = flags.get("name") ?? hostname();
      const rx = await startReceiver(dest, { port, streams, dataPort });
      const b = beacon ? startBeacon(rx.address.port, name) : null;
      stdout.write(
        `hypersend receiver: dest=${dest} port=${rx.address.port}` +
          `${beacon ? ` (beaconing as \"${name}\")` : ""}\n` +
          `waiting for a sender…\n`,
      );
      try {
        const files = await rx.done;
        stdout.write(`\nreceived ${files.length} file(s):\n`);
        for (const f of files) stdout.write(`  ✔ ${f.path} (${fmtBytes(f.size)})\n`);
      } finally {
        b?.stop();
        // Close the listener too: without this the process outlives the
        // batch with a dangling handle and never returns to the shell.
        rx.stop();
      }
      return;
    }

    case "send": {
      if (pos.length === 0) usage();
      const explicitHost = flags.get("to");
      const peer = explicitHost
        ? { host: explicitHost, port }
        : await (async () => {
            stdout.write("searching for receivers on this network…\n");
            const found = await discoverPeer(5_000, flags.get("peer-name"));
            stdout.write(`found ${found.name} at ${found.host}:${found.port}\n`);
            return found;
          })();

      // --extra-path accepts ip or ip:dataPort (e.g. 127.0.0.1:44012 through
      // `adb forward` = a USB-cable path). Repeat or comma-separate for more.
      const extraPaths = (flags.get("extra-path") ?? "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .map((entry, i) => {
          const [h, dp] = entry.split(":");
          const dataPort = dp ? Number.parseInt(dp, 10) : undefined;
          return {
            label: dataPort === 44012 ? "usb" : `path${i + 2}`,
            host: h ?? "127.0.0.1",
            ...(dataPort ? { dataPort } : {}),
          };
        });
      const targets = [
        { label: "wifi", host: peer.host, port: peer.port ?? port },
        ...extraPaths,
      ];
      const result = await sendFiles(pos, targets, {
        streams,
        onProgress: renderProgress,
      });
      stdout.write(
        `\nsent ${result.files} file(s), ${fmtBytes(result.bytes)} ` +
          `in ${(result.elapsedMs / 1000).toFixed(2)}s → ${result.mibsPerSec.toFixed(1)} MiB/s\n`,
      );
      return;
    }

    case "bench": {
      const { runLocalBench } = await import("./bench.js");
      const sizeMb = Number.parseInt(flags.get("size") ?? "", 10) || 256;
      const result = await runLocalBench(sizeMb);
      stdout.write(
        `local bench (${sizeMb} MB): ${result.mibsPerSec.toFixed(1)} MiB/s ` +
          `(${result.files} file(s), sha256 verified)\n`,
      );
      return;
    }

    default:
      usage();
  }
}

main().catch((err: unknown) => {
  console.error("hypersend:", err instanceof Error ? err.message : err);
  exit(1);
});
