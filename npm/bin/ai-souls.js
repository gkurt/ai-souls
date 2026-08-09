#!/usr/bin/env node
// Thin launcher: pick the binary for this machine and get out of the way.
//
// Every argument, the exit code and the signal are passed straight
// through, because `ai-souls fire <event>` runs on Claude Code's
// critical path and `ai-souls status` is read by scripts. Node is here
// only to choose a file — it does no work of its own.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const vendor = join(root, "vendor");

// The directory name is exactly Node's own `${platform}-${arch}`, so
// there is no table here to fall out of date.
const slot = `${process.platform}-${process.arch}`;
const binary = join(vendor, slot, process.platform === "win32" ? "ai-souls.exe" : "ai-souls");

if (!existsSync(binary)) {
  const available = existsSync(vendor)
    ? (await readdir(vendor, { withFileTypes: true }))
        .filter((entry) => entry.isDirectory())
        .map((entry) => entry.name)
    : [];
  process.stderr.write(
    `ai-souls: no binary for ${slot}.\n` +
      (available.length
        ? `This package ships: ${available.join(", ")}.\n`
        : "This package shipped no binaries at all, which means it was packed wrong.\n") +
      `Build one from source with the Native SDK: https://github.com/native-sdk\n`,
  );
  process.exit(1);
}

const child = spawn(binary, process.argv.slice(2), { stdio: "inherit" });

// Ctrl-C and friends belong to the child while it is running.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    if (!child.killed) child.kill(signal);
  });
}

child.on("error", (error) => {
  process.stderr.write(`ai-souls: could not run ${binary}: ${error.message}\n`);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  // Reproduce a signal death as a signal death rather than flattening
  // it to an exit code, so a shell reports what actually happened.
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});
