// Changelogs and versioning, via Tegami (https://tegami.fuma-nama.dev).
//
// Tegami versions here but never publishes. The npm package is not a
// directory in this repo — it is assembled into `dist/npm` by
// `tools/package-npm.mjs` out of binaries built on two different
// runners, so a publish from this machine, or from Tegami's own Ubuntu
// job, would ship a package with no binaries in it. `npm/package.json`
// is marked `"private": true` for exactly that reason: Tegami's npm
// provider versions private packages and refuses to publish them.
// `package-npm.mjs` drops the flag when it stages the real package.
//
// So the flow is:
//
//   1. Write `.tegami/*.md` for the change.
//   2. `tegami ci` on main opens a Version Packages PR.
//   3. Merging it bumps `npm/package.json` + `app.zon` and writes
//      CHANGELOG.md, and `version.yml` pushes a `v<version>` tag.
//   4. The tag runs `release.yml`, which is where the binaries are.

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tegami } from "tegami";
import type { TegamiPlugin } from "tegami";
import { runCli } from "tegami/cli";
import { github } from "tegami/plugins/github";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

/// Carry the new version across to `app.zon`.
///
/// `applyCliDraft` is the only hook that runs after the bumped
/// `package.json` is on disk — `applyDraft` fires before the write, so
/// reading the version there would give the old one. `enforce: "pre"`
/// puts this ahead of the GitHub plugin, whose own `applyCliDraft` does
/// a `git add -A`; that is what sweeps `app.zon` into the Version
/// Packages commit.
function syncAppManifest(): TegamiPlugin {
  return {
    name: "sync-app-zon",
    enforce: "pre",
    applyCliDraft() {
      execFileSync(process.execPath, ["tools/sync-version.mjs"], { cwd: root, stdio: "inherit" });
    },
  };
}

const pkg = JSON.parse(await readFile(join(root, "npm", "package.json"), "utf8"));
if (pkg.private !== true) {
  throw new Error(
    "npm/package.json must stay `\"private\": true` — see the note at the top of this file.",
  );
}

const paper = tegami({
  plugins: [
    syncAppManifest(),
    github({
      repo: "gkurt/ai-souls",
      versionPr: { base: "main" },
      // The release for a tag is created by `release.yml`, which is the
      // only job that has the binaries to attach.
      release: false,
    }),
  ],
});

await runCli(paper);
