# Contributing

Everything here is the stuff a user does not need and a contributor
does. For what the app *is*, see the [README](README.md); for the house
rules an agent should follow, see [AGENTS.md](AGENTS.md).

## Setup

```bash
npm install -g @native-sdk/cli
```

```bash
native dev      # run with hot reload
native test     # the test suite
native check    # validate app.zon
native build    # ReleaseFast binary into zig-out/bin/
native package  # platform bundle
```

```bash
node tools/package-npm.mjs   # stage dist/npm from the last build
```

There is no lint or format step. `zig fmt` is the formatter, the Zig
extension runs it on save, and nothing in CI checks style.

## Architecture

`src/souls.zig` is the comptime catalog, `src/config.zig` an
allocation-free codec (so `update` can parse and serialize without an
allocator), `src/throttle.zig` the on-disk record of when each event
last drew, `src/app.zig` the whole Model/Msg/update, `src/views.zig`
both windows' widget trees, `src/hooks.zig` the JSON merge, and
`src/cli.zig` the non-GUI verbs.

`update` never reads the clock, the environment, or the filesystem
directly. Paths and the display size are resolved in `main` and carried
in the model; everything else goes through the effects channel. That is
what lets the suite drive the whole app without a window.

**A screen is a process.** Nothing stays resident.

| Invocation | What it does |
| --- | --- |
| `ai-souls fire <event>` | resolves the event, draws its banner, exits — this is what hooks run |
| `ai-souls "..."` | the same, for a headline you typed |
| `ai-souls settings` | opens the settings window; closing it ends the process |
| `ai-souls install` | merges the enabled hooks into `~/.claude/settings.json` |

A hook's `fire` reads the config, and if that event is off it exits
before touching a window system at all. If it is on, the process becomes
the banner, holds it, and quits with it. Measured on Windows from a
completely dead start, four runs: visible at 269–458 ms, median 295 ms.

This replaced a resident app that held an always-open transparent window
and polled a trigger file five times a second, on the belief that
revealing a canvas window cost ~2.5 s and had to be paid once at
startup. The number was wrong (see [Platform notes](#platform-notes)).
The resident process cost ~3.5% of a core continuously, and meant that
after a reboot nothing was listening until you started the app by hand.

## Why hooks run a copy

A hook names its command by absolute path, and every path a package
manager hands out is temporary in some way. npm's global prefix is
versioned, so an upgrade moves the binary. npx is worse: it unpacks into
a cache directory npm deletes on its own schedule, and it does not
consult a global install either — `npx --no-install ai-souls` fails with
"could not determine executable to run" even with the global shim on
PATH.

Neither failure would say anything. Our hooks are `async` with a five
second timeout, so Claude Code swallows the error and the screens just
stop appearing one day.

So `install` copies the binary and the sounds into `~/.ai-souls/bin` and
points the hooks there. That path is ours: it survives an upgrade, an
`npm uninstall -g`, and an npx cache being collected ten minutes later.
The copy is a whole working install rather than a launcher. `uninstall`
takes it away again, and re-running `install` refreshes it — if a
running app is holding the old one open, the install still succeeds
against the existing copy and says so.

Making the hook itself say `npx ai-souls fire …` costs too much for this
path. Median of seven runs on the same machine:

| hook command | median |
| --- | --- |
| absolute path to the binary | **2 ms** |
| `ai-souls` through the npm PATH shim | 187 ms |
| `npx ai-souls`, package already in local `node_modules` | 695 ms |

That is npx's best case; the usual one adds a registry round trip, which
fails offline and can outrun the hook timeout. It would also mean every
`SessionStart` running whatever the registry currently serves under that
name, which is a lot of standing trust for a banner.

## Sounds

Gong, Choir, Chime, Ember and Thud are synthesized from scratch by
`tools/make-sounds.mjs` — a few oscillators and envelopes each.

```bash
node tools/make-sounds.mjs
```

ffmpeg on PATH does the mp3 encode. mp3 is the one format all three
platform audio backends decode.

"You Died" is the exception: a supplied recording, not something this
repo generates. It is not in the generator's voice table, so a
regeneration leaves it alone.

To add your own, drop an mp3 in `assets/sounds/`, append it to the
`Sound` enum in `src/souls.zig`, and give it a `durationMs`. Two rules:

- **Append, never reorder.** Those numbers are what `config.txt` stores.
- **`durationMs` must match the file.** A screen is sized against it,
  because the overlay stops audio when it ends. Get it wrong and the
  sound is cut off with nothing to show for it.

## Packaging

The npm package is a single tarball carrying one binary per platform
under `vendor/<platform>-<arch>/`, with a Node launcher that picks one
and execs it. Two slots ship today:

| Slot | Built on | |
| --- | --- | --- |
| `win32-x64` | `windows-latest` | `x86_64-windows-gnu` |
| `darwin-universal` | `macos-14` | `arm64` + `x86_64`, fused with `lipo` |

macOS is one universal binary rather than two arch slots, so the
launcher looks for `darwin-universal` when there is no slot for the
exact arch. A platform with no binary gets a clear error rather than a
mystery.

Only `win32-x64` can be built on a Windows machine — the macOS target
needs Apple's SDK. CI builds both on their own runners and stages them
into one package.

CI names its targets explicitly instead of building for the host: a
native build compiles for the runner's *detected CPU features*, so a
binary built on a machine with AVX-512 can crash on one without it.

**Release builds need `-Dtrace=off`.** The SDK's trace default is
`events`, and since `fire` boots the runtime in the foreground that
chatter would go straight to the hook's stdout.

## Releasing

Changelogs and versions are managed by
[Tegami](https://tegami.fuma-nama.dev). Nothing about a release is typed
by hand except the description of what changed. Write that in the same
commit as the change:

```bash
bun run tegami
```

It writes a `.tegami/*.md` file naming the bump type and what a user
would notice. From there:

| | |
| --- | --- |
| **`ci.yml`** — push, PR | `native check`, `native test`, `native build` on Windows and macOS. Keeps each binary as a 14-day artifact, so the macOS build nobody here can compile is always one download away. |
| **`version.yml`** — push to `main` | `tegami ci` turns pending changelogs into a **Version Packages** PR: bumped `npm/package.json` + `app.zon`, and `CHANGELOG.md`. Merging it pushes a `v<version>` tag and starts the release. |
| **`release.yml`** — dispatched by `version.yml`, or a `v*` tag pushed by hand | Builds both slots, fuses the macOS one, packs the tarball, drafts a GitHub release with the changelog as its notes, and publishes to npm. |

So the decision a human makes is **merging the Version Packages PR**.

Two things stay deliberately manual:

- **The GitHub release is a draft.** The assets are persisted and the
  notes written; publishing it is a click.
- **npm publishing** goes through
  [trusted publishing](https://docs.npmjs.com/trusted-publishers) — OIDC
  against `release.yml`, no `NPM_TOKEN` anywhere. The `NPM_PUBLISH`
  repository variable gates it, so there is a switch to flip that is not
  a revert.

### Why the tag does not start the release by itself

Anything `GITHUB_TOKEN` pushes is invisible to `on: push`. That is how
GitHub stops a workflow triggering itself forever, and it is not
optional. It cost this repo its v0.1.0 release: `version.yml` pushed the
tag, said `release.yml takes it from here`, and nothing built.

`workflow_dispatch` is the one documented exception, so the tag job asks
for the run by name — against the tag, because every job in `release.yml`
gates on `startsWith(github.ref, 'refs/tags/v')`. If it ever fails, the
tag is already pushed and one command finishes the job:

```bash
gh workflow run release.yml --ref v0.2.0
```

The same rule is why the Version Packages PR gets no CI of its own.
`main` is protected against force-pushes and deletion but does not
require status checks, so the PR merges normally. Giving Tegami a
personal access token instead of `github.token` would fix both at once.

### Why the version lives in two files

`npm/package.json` is the version of record, because it is the file
Tegami bumps. `app.zon` carries the same number because the Native SDK
reads it. `tools/sync-version.mjs` copies one to the other from Tegami's
`applyCliDraft` hook, CI checks they agree, and the packager refuses to
stage a package where they don't.

`npm/package.json` is also marked `"private": true`, which is what stops
Tegami publishing it: the real package does not exist as a directory in
this repo, it is assembled into `dist/npm` out of binaries from two
runners. The packager drops the flag when it stages the public copy.

## Platform notes

macOS uses the same code paths (`NSFloatingWindowLevel`,
`ignoresMouseEvents`, a clear window background) and is expected to work.
CI compiles it and runs the suite on a macOS runner, so it is known to
build and known to pass — but nobody has watched a banner appear there.
Everything below was measured on Windows 11.

- **A canvas window reveals on its first present, not on a timer.** This
  was long believed to cost ~2.5 s on the Win32 host, and the permanent
  overlay window — and the resident process that held it — existed to
  pay it once. The number was wrong. The host shows a canvas window from
  `showWindowImplicit` on its first successful present; the deferred-show
  deadline is a safety net for windows that never present, and it is
  `kDeferredShowDeadlineMs = 1000`, never reached in practice. Measured
  on SDK 0.8.1, five runs, window created on demand: visible at 191–318
  ms, median 275 ms. Worth re-measuring on macOS, which has its own show
  policy.
- **The overlay window is only as tall as the banner**, not as tall as
  the screen, and this is the entire framerate budget. A transparent
  top-level window cannot use the Direct2D path — `UpdateLayeredWindow`
  replaces the whole top-level image and cannot compose child HWNDs —
  so every frame is rasterized on the CPU and the cost tracks the
  window's area. Measured on a 4K/150% display:

  | overlay window | animation |
  | --- | --- |
  | full screen (1440pt) | 6 fps |
  | 320pt band | 16 fps |
  | **240pt band** (shipping) | **21 fps** |
  | 240pt band, opaque | 28 fps |

  Asking the animation timer for a shorter interval does not help and
  slightly hurts: effect timers arrive as `WM_TIMER`, the lowest-
  priority Win32 message, so a busy frame loop starves them regardless.
  4ms measured 20 fps against 16ms's 21. `timeBeginPeriod(1)` landed
  inside the noise and was dropped.
- **Starting a sound freezes the message loop for two seconds**, and
  there is nothing the app can do about it: `playAudio` reaches a host
  that builds a Media Foundation session, topology and audio renderer
  synchronously on the loop thread. Measured as the largest gap between
  two animation frames, three screens each:

  | | frames in 2.6s | largest gap |
  | --- | --- | --- |
  | silent | 59-61 | 60-66 ms |
  | with a sound | 44-52, bunched | **2029-2068 ms** |

  It is a flat cost, not a decode cost: 0.9s/15KB and 7.1s/112KB files
  both pay 2.03s, and the second and third plays pay it again. Two
  things follow from it.

  The sound starts *after* the fade-in rather than with it, so the
  freeze cannot land on the one animation the user is watching for. And
  `advanceOverlay` refuses to count the part of a freeze that would
  otherwise skip the fade-out — a screen frozen through its hold was
  holding anyway, but one that comes back from the freeze already past
  its own ending vanishes without ever fading, which is exactly what it
  used to do. Only the overshoot is given back, so a 2.6s screen runs
  about 3.0s rather than the 4.6s that forgiving the whole freeze would
  cost. A machine that does not freeze pays none of this.
- **The bar's soft edges are stacked strips, and they must be plain
  layout boxes.** There is no gradient fill for widget backgrounds, and
  the `chrome` builder that does have one is main-canvas only. Built out
  of `.panel` each strip draws that widget's border, and 48 hairlines
  through the fade turn the gradient into a flat lighter block.
- **A screen process hides the settings window with a raw `SW_HIDE`,**
  not with the SDK's `closeWindow`. The shell window is declared in
  `app.zon` and therefore always created, but a banner must not open a
  settings window over itself. `closeWindow` is not the answer: the
  Win32 host documents that runtime-initiated closes bypass the
  `close_policy` hook and really destroy the window — measured as
  `window_closed` followed immediately by `stop`, which would end the
  process mid-banner.
- **`AI_SOULS_OPAQUE=1`** runs the overlay as a solid window: the band
  stops being see-through, and in exchange it regains the Direct2D path
  and runs noticeably smoother. It is also the fallback for
  remote-desktop and compositor setups that cannot present a layered
  window at all, where a solid banner beats an invisible one.
- **Two things about the overlay window are fixed from Win32 directly**
  (`src/overlay_style.zig`), because the SDK's `WindowDescriptor` cannot
  express them. It is a borderless top-level window — `WS_POPUP` with no
  owner — which the shell would otherwise give a taskbar button and an
  Alt+Tab entry, so `WS_EX_TOOLWINDOW` and `WS_EX_NOACTIVATE` are set on
  it. And the descriptor's `x`/`y` are never applied: the Win32 host
  passes `CW_USEDEFAULT` to `CreateWindowExW`, which parks the bar at
  the top of the screen, so it is moved to the middle afterwards.
- **`native automate snapshot` is not trustworthy here.** It served a
  cached snapshot from a long-dead process throughout development —
  check `publisher_pid` against a live process before believing it.
- **Screenshotting the overlay needs `CAPTUREBLT`.** It is a layered
  window, and a plain `BitBlt`/`CopyFromScreen` of the desktop silently
  omits those — it returns a perfectly good screenshot with no banner in
  it. Any capture tool must also be per-monitor DPI aware, or Windows
  virtualizes its coordinates and window rects and the numbers quietly
  disagree with the app's.

## The rename

An install from before the product became AI Souls is picked up on first
run: `~/.claude-souls/config.txt` is adopted (copied, not moved), and
hooks written under the old name are still recognised, so `install`
replaces them rather than leaving every screen firing twice.
