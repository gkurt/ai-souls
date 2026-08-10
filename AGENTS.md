# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

AI Souls is a Zig desktop app built on the [Native SDK](https://native-sdk.dev).
It installs global Claude Code hooks and flashes Dark Souls transition banners
over whatever you are doing. It ships to npm as `ai-souls`, a single tarball
carrying a prebuilt binary per platform.

## Commands

```bash
native build          # ReleaseFast binary into zig-out/bin/
native test           # the whole suite
native check          # validate app.zon and the markup
native dev            # Debug build, runs it

node tools/package-npm.mjs   # stage dist/npm, ready for `npm pack`
node tools/sync-version.mjs  # app.zon version := npm/package.json version
bun run tegami               # write a changelog entry for a change
```

There is no lint or format step. `zig fmt` is the formatter and the Zig
extension runs it on save; nothing in CI checks style.

`native build`/`native test` take `-D` flags straight through to `zig build`,
which is how CI pins targets: `native build --yes -Dtarget=aarch64-macos`.

## Project structure

| Path | |
| --- | --- |
| `src/main.zig` | entry point: resolves paths and the display, picks a mode, owns the Win32/AppKit helper threads |
| `src/app.zig` | the whole Model/Msg/update — the TEA loop |
| `src/souls.zig` | the comptime event catalog and the sound bank |
| `src/config.zig` | allocation-free config codec, shared by `config.txt` and the trigger protocol |
| `src/cli.zig` | every non-GUI verb (`install`, `fire`, `status`, …) and the trigger handshake |
| `src/hooks.zig` | the JSON merge into `~/.claude/settings.json` |
| `src/paths.zig` | every path the app knows, resolved once |
| `src/runtime_copy.zig` | the copy under `~/.ai-souls/bin` that installed hooks actually run |
| `src/views.zig` | both windows' widget trees |
| `src/screen.zig` | the primary display's size, read once in `main` |
| `src/overlay_style.zig` | the raw Win32 the SDK does not expose |
| `src/tests.zig` | end-to-end tests over the real update loop |
| `npm/` | the npm package's manifest and Node launcher — **not** the published tree |
| `tools/` | packaging and version scripts |
| `scripts/tegami.mts` | changelog and versioning config |

## Architecture

`update` never reads the clock, the environment, or the filesystem directly.
Paths and the display size are resolved in `main` and carried in the model;
everything else goes through the effects channel. That is what makes the suite
able to drive the whole app without a window.

Two invariants worth knowing before you change things:

- **The `Sound` and event enums are serialized as integers** into
  `~/.ai-souls/config.txt`. Append to them; never reorder.
- **The overlay window is created once at startup and never destroyed.** It is
  transparent and click-through, and `fx.closeWindow` really does destroy it
  and stop the app — hiding is `SW_HIDE` from the helper thread.

## Releasing

Versions and changelogs are managed by [Tegami](https://tegami.fuma-nama.dev).
When a change is user-facing, add a `.tegami/*.md` entry in the same commit:

```md
---
packages:
  ai-souls: minor
---

## What changed, in the user's words

Why they would care.
```

`packages` takes `major` / `minor` / `patch`. Keep entries short and about
behaviour, not implementation.

The rest is automatic: `version.yml` opens a Version Packages PR, merging it
tags `v<version>`, and `release.yml` builds both platforms and drafts the
release. See the README's release section for the parts that still need hands.

## Coding conventions

- Prefer colocation.
- Match the surrounding code's comment density and naming. This codebase
  comments *why*, at the top of a file or above a non-obvious decision, and
  leaves the *what* to the code.
- Prefer early returns to reduce nesting.
- If a file gets too long (>600 lines), refactor into smaller modules.
- Check for an existing helper before adding one. Avoid duplication.
- Remove dead and commented-out code; don't preserve old APIs unless asked.
- When moving code, don't leave a re-export behind. Update every caller and
  delete the old definition, so there is a single source of truth.
- Zig 0.16: `std.Io` is passed explicitly. There is no `std.time.milliTimestamp`
  and no `std.Thread.sleep`. If the compiler says a `std` member is missing, the
  code is using a pre-0.16 idiom — run `native skills get zig`.

## Documentation

When changing user-facing behaviour, update the docs in the same change:
README.md, this file, and the `--help` text in `src/cli.zig`. Documentation must
not go stale.
