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
//   2. `tegami ci` on main opens a release PR — `chore: release
//      v<version>`, see `versionPr.create` below.
//   3. Merging it bumps `npm/package.json` + `app.zon` and writes
//      CHANGELOG.md, and `version.yml` pushes a `v<version>` tag.
//   4. The tag runs `release.yml`, which is where the binaries are.

import { execFileSync, spawnSync } from "node:child_process";
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

/// What this clone's `.git/config` said before Tegami touched it.
///
/// Read at module scope, which is the last moment before any plugin
/// hook can run.
const identityBefore = {
  "user.name": localGitConfig("user.name"),
  "user.email": localGitConfig("user.email"),
};

function localGitConfig(key: string): string | undefined {
  const result = spawnSync("git", ["config", "--local", "--get", key], { cwd: root, encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : undefined;
}

/// Put the git identity back on a developer's machine.
///
/// Tegami's `git` plugin — which `github()` includes — configures
/// `user.name`/`user.email` to `github-actions[bot]` from its `initCli`
/// hook whenever `process.env.CI` is set. It uses a plain `git config`,
/// so it writes to THIS clone's `.git/config` and stays there, and the
/// next commit you make is authored by the bot.
///
/// That is correct on a runner, where the checkout is thrown away. It is
/// not correct anywhere else, and `CI` is set by plenty of things that
/// are not GitHub Actions. There is no option to turn it off, so undo it
/// — restoring exactly what was there, rather than blindly unsetting,
/// because a repo-local identity may have been someone's deliberate
/// choice.
function keepGitIdentity(): TegamiPlugin {
  return {
    name: "keep-git-identity",
    enforce: "post",
    initCli() {
      if (process.env.GITHUB_ACTIONS === "true") return;
      for (const [key, before] of Object.entries(identityBefore)) {
        const args = before === undefined ? ["config", "--unset", key] : ["config", key, before];
        spawnSync("git", args, { cwd: root });
      }
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
    keepGitIdentity(),
    github({
      repo: "gkurt/ai-souls",
      versionPr: {
        base: "main",
        // The release version in the PR title ("chore: release v0.3.1")
        // rather than Tegami's flat "Version Packages", so the merge
        // commit on main says which release it was.
        //
        // `create` runs AFTER the draft is applied, so the graph already
        // holds the bumped version — read it straight off. Calling
        // `bumpVersion` here would bump a second time.
        create() {
          const version = this.graph.get("npm:ai-souls")?.version;
          return { title: version ? `chore: release v${version}` : "chore: release" };
        },
      },
      // The release for a tag is created by `release.yml`, which is the
      // only job that has the binaries to attach.
      release: false,
    }),
  ],
});

await runCli(paper);
