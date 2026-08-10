#!/usr/bin/env node
// Assemble the npm package in dist/npm.
//
// One package for every platform rather than a family of
// optionalDependencies: the binary is about 6 MB, so three of them plus
// the sounds is a download people will not notice, and a single tarball
// has no version-skew failure mode between the launcher and the slot it
// resolves.
//
//   node tools/package-npm.mjs                     this machine's slot
//   node tools/package-npm.mjs --keep              keep slots already staged
//   node tools/package-npm.mjs --keep \            stage someone else's
//     --slot darwin-arm64 --binary path/to/ai-souls
//
// The last form is how the mac slot gets filled: a build job per
// platform uploads its binary and one assemble job stages them all
// (see .github/workflows/release.yml). It cannot be built here — the
// macOS target needs Apple's SDK, which only a macOS host has.

import { cp, mkdir, readFile, rm, writeFile, readdir, chmod } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "dist", "npm");
const args = process.argv.slice(2);
const keep = args.includes("--keep");
const flag = (name) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 ? args[at + 1] : undefined;
};

// What a complete release carries. `darwin-universal` is one lipo'd
// binary rather than two arch slots, which the launcher knows to look
// for; the tarball is ~6 MB lighter for it.
const shipped = ["win32-x64", "darwin-universal"];

const slot = flag("slot") ?? `${process.platform}-${process.arch}`;
const exeName = slot.startsWith("win32") ? "ai-souls.exe" : "ai-souls";
const built = flag("binary") ?? join(root, "zig-out", "bin", exeName);

if (!existsSync(built)) {
  console.error(`no binary at ${built} — run \`native build\` first`);
  process.exit(1);
}

// `npm/package.json` is the version of record — it is the file Tegami
// bumps. `app.zon` carries the same number for the Native SDK's sake,
// and disagreeing with it means something wrote one and not the other,
// so the package would not match the binary it wraps.
const pkg = JSON.parse(await readFile(join(root, "npm", "package.json"), "utf8"));
const version = pkg.version;
const manifest = await readFile(join(root, "app.zon"), "utf8");
const zonVersion = manifest.match(/\.version\s*=\s*"([^"]+)"/)?.[1];
if (zonVersion !== version) {
  console.error(
    `version drift: npm/package.json says ${version}, app.zon says ${zonVersion}\n` +
      `Run \`node tools/sync-version.mjs\`.`,
  );
  process.exit(1);
}

// The template stays private so Tegami never publishes it from `npm/`,
// where there are no binaries — see the note in `scripts/tegami.mts`.
// The staged copy is the public one, so the flag comes off here.
if (pkg.private !== true) {
  console.error("npm/package.json must stay `\"private\": true` — see scripts/tegami.mts");
  process.exit(1);
}
delete pkg.private;

if (!keep) await rm(out, { recursive: true, force: true });
await mkdir(join(out, "vendor", slot), { recursive: true });

await cp(join(root, "npm", "bin"), join(out, "bin"), { recursive: true });
await cp(join(root, "assets"), join(out, "assets"), { recursive: true });
await cp(join(root, "README.md"), join(out, "README.md"));
// Written by Tegami next to the manifest it versions; absent until the
// first release has been cut.
const changelog = join(root, "npm", "CHANGELOG.md");
if (existsSync(changelog)) await cp(changelog, join(out, "CHANGELOG.md"));
await cp(built, join(out, "vendor", slot, exeName));
// npm preserves the mode bit, and a binary that is not executable is a
// confusing failure on the far side.
if (!slot.startsWith("win32") && process.platform !== "win32") {
  await chmod(join(out, "vendor", slot, exeName), 0o755);
}

await writeFile(join(out, "package.json"), `${JSON.stringify(pkg, null, 2)}\n`);

const slots = (await readdir(join(out, "vendor"), { withFileTypes: true }))
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

console.log(`ai-souls@${version} staged in dist/npm`);
console.log(`  binaries: ${slots.join(", ")}`);
for (const missing of shipped) {
  if (!slots.includes(missing)) console.log(`  MISSING:  ${missing}`);
}
console.log("");
console.log("Inspect it with `npm pack --dry-run` in dist/npm before publishing.");
