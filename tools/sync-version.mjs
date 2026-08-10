#!/usr/bin/env node
// Keep `app.zon`'s version equal to the npm package's.
//
//   node tools/sync-version.mjs           write app.zon from npm/package.json
//   node tools/sync-version.mjs --check   exit 1 if they disagree
//
// There are two manifests because there are two toolchains: the Native
// SDK reads `app.zon`, and npm reads `package.json`. Only one of them
// can be the writer, and it has to be `package.json` — that is the file
// Tegami bumps when a release is versioned.
//
// So this runs from Tegami's `applyCliDraft` hook (see
// `scripts/tegami.mts`), which fires after the bump is on disk and
// before the Version Packages PR is committed, and `--check` runs in CI
// as the backstop for anyone who edits a version by hand.

import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const manifest = join(root, "app.zon");
const check = process.argv.includes("--check");

const pkg = JSON.parse(await readFile(join(root, "npm", "package.json"), "utf8"));
const zon = await readFile(manifest, "utf8");

const version = /\.version\s*=\s*"([^"]+)"/;
const found = zon.match(version);
if (!found) {
  console.error("could not find .version in app.zon");
  process.exit(1);
}

if (found[1] === pkg.version) {
  console.log(`app.zon and npm/package.json agree on ${pkg.version}`);
  process.exit(0);
}

if (check) {
  console.error(
    `version drift: app.zon says ${found[1]}, npm/package.json says ${pkg.version}\n` +
      `Run \`node tools/sync-version.mjs\` to bring app.zon in line.`,
  );
  process.exit(1);
}

await writeFile(manifest, zon.replace(version, `.version = "${pkg.version}"`));
console.log(`app.zon ${found[1]} -> ${pkg.version}`);
