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
which is how CI pins targets and silences the runtime's trace output:
`native build --yes -Dtrace=off -Dtarget=aarch64-macos`. **Release builds need
`-Dtrace=off`** — the default is `events`, and since `fire` boots the runtime
in the foreground, that chatter lands on the hook's stdout.

## Project structure

| Path | |
| --- | --- |
| `src/main.zig` | entry point: resolves paths and the display, picks a mode, owns the Win32/AppKit helper threads |
| `src/app.zig` | the whole Model/Msg/update — the TEA loop |
| `src/souls.zig` | the comptime event catalog and the sound bank |
| `src/config.zig` | allocation-free config codec for `config.txt` |
| `src/throttle.zig` | the on-disk record of when each event last drew, and the rules over it — the floor, the ranking, the per-event window |
| `src/cli.zig` | every non-GUI verb (`install`, `fire`, `status`, …) and the trigger handshake |
| `src/console.zig` | where CLI output goes on Windows, where a GUI-subsystem binary has no terminal to print to |
| `src/hooks.zig` | the JSON merge into `~/.claude/settings.json` |
| `src/paths.zig` | every path the app knows, resolved once |
| `src/runtime_copy.zig` | the copy under `~/.ai-souls/bin` that installed hooks actually run |
| `src/views.zig` | both windows' widget trees |
| `src/screen.zig` | the primary display's size, read once in `main` |
| `src/overlay_style.zig` | the raw Win32 and AppKit the SDK does not expose |
| `src/tests.zig` | end-to-end tests over the real update loop |
| `npm/` | the npm package's manifest and Node launcher — **not** the published tree |
| `tools/` | packaging and version scripts |
| `scripts/tegami.mts` | changelog and versioning config |

## Architecture

`update` never reads the clock, the environment, or the filesystem directly.
Paths and the display size are resolved in `main` and carried in the model;
everything else goes through the effects channel. That is what makes the suite
able to drive the whole app without a window.

Invariants worth knowing before you change things:

- **The `Sound` and event enums are serialized as integers** into
  `~/.ai-souls/config.txt`. Append to them; never reorder. The event
  *catalog* is different: it is keyed by `Event.key` everywhere it is
  written down, so rows can be reordered freely — index into
  `Config.events` with `souls.indexOfKey`, never with a literal.
- **A `.death` row sounds like `.you_died`.** The red screen and that
  sting are one thing; a catalog test enforces it, and `ai-souls
  "..."` applies the same rule when no `--sound` was given.
- **`Sound.durationMs` must match the files in `assets/sounds`.** A
  screen is sized against it, because the overlay stops audio when it
  ends — get it wrong and the sting is cut off with nothing to show
  for it. Re-render a sound, re-measure it.
- **A screen is a process.** `fire` resolves the event and becomes the banner;
  when the overlay ends it calls `fx.quitApp()`. Nothing is resident, so any
  new timer or poll you add runs on someone's machine only while a banner is
  up — keep it that way.
- **The settings window is hidden with a raw `SW_HIDE` in a screen process,**
  `orderOut:` on macOS, never `fx.closeWindow`: a runtime-initiated close
  really destroys the window and stops the app, which would kill the banner.
  Both wait for the window to be visible first — the host's own reveal
  would undo an earlier hide.
- **No window this app declares may activate.** `activate_on_show =
  false` on the overlay AND on the shell window — in `app.zon` too, since
  the host creates that one before any app code runs. A banner's process
  gets a shell window like every other, and its reveal taking the
  keyboard is the whole bug. It costs the settings window its focus on
  open, which is the trade; there is no `focusWindow` effect to undo it
  with. A screen process additionally drops to
  `NSApplicationActivationPolicyAccessory` so it has no Dock tile and no
  Cmd-Tab entry — screen processes only, or the settings app loses both.
- **No host applies the overlay descriptor's `x`/`y`.** Win32 passes
  `CW_USEDEFAULT`; macOS takes the size and puts the window where AppKit
  likes, which with a second display attached is not on the right one.
  So the banner is moved once it exists — `overlay_style` on both
  platforms, from the frame `main.bandFrame` works out. Delete either
  half and the bar is wherever the window system felt like.
- **A verb's output on Windows has to go and find the terminal.** The
  release binary is GUI-subsystem, so Windows never attaches it to the
  console that launched it and every `say` lands nowhere — measured as a
  completely empty console buffer while `install` wrote the settings
  file. `console.out` keeps a redirected handle (a pipe is a parent
  reading us, and `status > file` must work) and otherwise attaches to
  the parent's console. Print through `say`, never `File.stdout()`.
- **The throttle is a file, and it is decided before the window opens.**
  `fire` reads `~/.ai-souls/fired.txt`, and a screen it decides against
  costs one read and exits `handled_ok` — a hook that reported failure
  over a suppressed decoration would be a bug. It is racy on purpose;
  see the module comment before adding a lock.
- **Every catalog row ships as `.death` / `.you_died`.** Not a style
  choice per event — the other five styles are unverified against the
  game, so none of them is a default until someone has checked one. A
  test enforces it. They all stay pickable.
- **`Event.priority` is what lets a screen replace one still on
  screen,** and replacing means `overlay_style.dismissOthers`
  terminating the other process. Two consequences: a banner's window
  title must stay distinct from the settings window's overlay title, or
  a hook takes the settings app down with it; and preemption is gated
  on `overlay_style.can_dismiss`, Win32-only, because drawing two
  banners over each other is worse than missing one. New rows must
  choose a rank — the field has no default on purpose.

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

`bun run tegami` is the only Tegami command you need locally — `version` and
`ci` are the workflows' job.

Tegami's `git` plugin rewrites this clone's `user.name`/`user.email` to
`github-actions[bot]` whenever `CI` is set in the environment, for any of its
commands. `scripts/tegami.mts` puts the identity back afterwards, so setting
`CI=1` to skip the interactive prompts is safe — but if you invoke Tegami some
other way, check `git config --local --get-regexp '^user\.'` before committing.

The rest is automatic: `version.yml` opens a Version Packages PR, merging it
tags `v<version>` and dispatches `release.yml`, which builds both platforms
and drafts the release. That dispatch is load-bearing — a tag pushed with
`GITHUB_TOKEN` never fires `on: push`, so nothing would build without it.
See CONTRIBUTING.md's release section for the parts that still need hands.

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
README.md, CONTRIBUTING.md, this file, and the `--help` text in
`src/cli.zig`. Documentation must not go stale.

README.md is for someone deciding whether to install it and living with it
afterwards. Everything else goes in CONTRIBUTING.md.

A feature landing does **not** earn a README section. The bar is: would a
person weighing this up, or living with it, be worse off not knowing? If
not, it belongs in CONTRIBUTING. Specifically keep out:

- Internals, measurements, workflow names, file formats.
- Tables enumerating how a mechanism is configured — rank orders,
  throttle windows, priority columns. State the *behaviour* in a line
  ("screens never stack, the noisy ones are rate-limited") and stop.
- Justifications for a default. Say what it is, not the argument behind
  choosing it.
- Platform caveats about which OS a feature works on.
- Anything about what has or has not been tested. See the memory rule:
  no claims the repo cannot prove.
- Where the project currently is in its own process — "not on npm yet",
  "coming in the next release", links to CI runs as a stopgap. The
  README describes the thing, not the state of shipping it. Anything
  written to be true only until the next release should not be written.

When a section grows past a screenful, that is the smell. Cut it back
rather than adding a subheading.
