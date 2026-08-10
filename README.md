# AI Souls

Dark Souls screens for your coding agent. A tool call fails and a
banner bleeds across your monitor; a session starts and another one
lights up. It is transparent, always on top, click-through, and gone in
a couple of seconds — you keep typing straight through it.

Claude Code is the only agent wired up today, but nothing is named after
it: the command, the config directory and the hook entries are all
`ai-souls`. An install from before the rename is picked up on first run
— `~/.claude-souls/config.txt` is adopted, and hooks written under the
old name are still recognised, so `ai-souls install` replaces them
rather than leaving every screen firing twice.

Out of the box every headline is just the event's own name — "Session
started", "Tool call failed". **YOU DIED** is a much better joke when
you chose it, so the settings window lets you write your own. Whatever
you type is SHOUTED: the uppercasing happens at render time, so the
setting keeps your text exactly as you wrote it.

It is set in [EB Garamond](https://github.com/octaviopardo/EBGaramond12)
(SIL Open Font License), embedded in the binary rather than borrowed
from the OS so the screen is the same face on Windows and macOS.

Built with [Vercel's Native SDK](https://github.com/vercel-labs/native):
declarative native views in Zig, no browser, no WebView, one binary.

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│  ───────────────────────────────────────────────    │
│                                                     │
│                  Y O U   D I E D                    │
│                                                     │
│  ───────────────────────────────────────────────    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Getting started

> **Not on npm yet.** Until the first release is published, grab a
> binary from the
> [latest CI run](https://github.com/gkurt/ai-souls/actions/workflows/ci.yml)
> or build one — see [Building it yourself](#building-it-yourself).

```bash
npx ai-souls install
```

That is it. Screens start appearing in every Claude Code session on the
machine, and they keep appearing after npm collects the npx cache —
`install` puts its own copy in `~/.ai-souls` and points the hooks there,
so nothing depends on the download surviving. See
[Why hooks run a copy](#why-hooks-run-a-copy).

Settings live in the tray icon, under **Open AI Souls**. The app appears
there the first time a screen fires.

### If you want the command as well

The hooks do not need it, but `ai-souls` is nicer to have on your PATH
than `npx ai-souls` — it is instant rather than ~700 ms, and it works
offline.

```bash
npm install -g ai-souls
ai-souls install
```

Either way, to see a screen right now:

```bash
npx ai-souls "YOU DIED"
```

## The command

```
ai-souls <message>         put a headline on screen
ai-souls settings          open the settings window
ai-souls install [agent]   write the enabled hooks into the agent's settings
ai-souls uninstall [agent] remove every AI Souls hook
ai-souls status            show paths and the current per-event settings
ai-souls events            list the event keys
ai-souls fire <event>      show a catalog event's screen (this is what hooks run)
ai-souls serve             run in the tray with no window
```

`agent` is optional and defaults to `claude`, the only one supported
today. It exists so that adding a second one does not change the shape
of the command line.

Prefix any of them with `npx` if you did not install globally. That is a
real install doing real work — `npx ai-souls install` is the
recommended way in — but it pays npm's resolution cost every time, so
the verbs you reach for often are worth a global install. See
[Why hooks run a copy](#why-hooks-run-a-copy) for why an npx install
outlives its own cache.

Anything that is not a verb is a headline, so quoting is optional and
`--` forces the issue:

```bash
ai-souls PRAISE THE SUN --style victory --sound choir
```

```bash
ai-souls -- status
```

| Option | |
| --- | --- |
| `--style <name>` | death, bonfire, victory, soul, hollow, covenant |
| `--sound <name>` | silent, gong, choir, chime, ember, thud, you-died |
| `--volume <0-100>` | |
| `--duration <ms>` | 600 to 10000 |
| `--subtitle <text>` | |

A message starts the app if nothing is running, and starts it in the
tray — asking for a banner should not open a settings window over the
top of it. The settings window closes to the tray rather than quitting,
because the app has to stay alive to answer hooks. Quit from the tray
menu.

## How it works

One binary wearing several hats, and one small file between them:

| Invocation | What it does |
| --- | --- |
| `ai-souls` | the app: settings window + the overlay |
| `ai-souls serve` | the same app, straight to the tray |
| `ai-souls fire <event>` | stamps `~/.ai-souls/trigger`; this is what hooks run |
| `ai-souls "..."` | stamps the same file with a whole screen |
| `ai-souls install` | merges the enabled hooks into `~/.claude/settings.json` |

The running app polls the trigger five times a second. A hook writes one
short line and exits, so nothing in Claude Code's critical path ever
waits on a window system — and if the app is not running, a hook's fire
is a no-op the next launch discards rather than replaying. A hook must
never start an app; a person typing a message expects one to be there,
so those two cases are deliberately different.

Which is why the app publishes `~/.ai-souls/alive`: a heartbeat, and the
newest trigger stamp it has acted on. `ai-souls "..."` waits to see its
own stamp come back before concluding nothing is listening. That is an
acknowledgement rather than a guess, which matters because the app can
be alive and unable to answer — starting a sound freezes the Win32
message loop for two seconds flat.

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
The copy is a whole working install rather than a launcher, so it keeps
working alone. `uninstall` takes it away again.

The alternative — making the hook itself say `npx ai-souls fire …` —
costs too much to be on this path. Measured on the same machine, median
of seven runs:

| hook command | median |
| --- | --- |
| absolute path to the binary | **2 ms** |
| `ai-souls` through the npm PATH shim | 187 ms |
| `npx ai-souls`, package already in local `node_modules` | 695 ms |

That is the best case for npx; the usual one adds a registry round trip,
which fails offline and can outrun the hook timeout. It would also mean
every `SessionStart` running whatever the registry currently serves under
that name, which is a lot of standing trust for a banner.

Re-running `install` refreshes the copy. If a running app is holding the
old one open — Windows will not replace a live image — the install still
succeeds against the existing copy and says so, rather than leaving you
to wonder which build is answering.

## Building it yourself

```bash
npm install -g @native-sdk/cli
```

```bash
native build          # zig-out/bin/ai-souls
node tools/package-npm.mjs   # dist/npm, ready for `npm pack`
```

The npm package is a single tarball carrying one binary per platform
under `vendor/<platform>-<arch>/`, with a Node launcher that picks one
and execs it. Two slots ship today:

| Slot | Built on | |
| --- | --- | --- |
| `win32-x64` | `windows-latest` | `x86_64-windows-gnu` |
| `darwin-universal` | `macos-14` | `arm64` + `x86_64`, fused with `lipo` |

macOS is one universal binary rather than two arch slots, so the
launcher looks for `darwin-universal` when there is no slot for the
exact arch. A platform with no binary at all gets a clear error from the
launcher rather than a mystery.

Only `win32-x64` can be built on a Windows machine — the macOS target
needs Apple's SDK. CI builds both on their own runners and stages them
into one package.

CI names its targets explicitly instead of building for the host. A
native build compiles for the runner's *detected CPU features*, so a
binary built on a machine with AVX-512 can crash on one without it.

## Releasing

Changelogs and versions are managed by
[Tegami](https://tegami.fuma-nama.dev). Nothing about a release is typed
by hand except the description of what changed.

Write that description in the same commit as the change:

```bash
bun run tegami
```

It writes a `.tegami/*.md` file naming the bump type and what a user
would notice. From there:

| | |
| --- | --- |
| **`ci.yml`** — push, PR | `native check`, `native test`, `native build` on Windows and macOS. Keeps each binary as a 14-day artifact, so the macOS build nobody here can compile is always one download away. |
| **`version.yml`** — push to `main` | `tegami ci` turns pending changelogs into a **Version Packages** PR: bumped `npm/package.json` + `app.zon`, and `CHANGELOG.md`. Merging it pushes a `v<version>` tag. |
| **`release.yml`** — `v*` tag | Builds both slots, fuses the macOS one, packs the tarball, and drafts a GitHub release with the changelog as its notes and the binaries attached. |

So the decision a human makes is **merging the Version Packages PR**.

That PR gets no CI of its own: GitHub does not trigger workflows for
pull requests created with `GITHUB_TOKEN`, which is how it avoids
workflow loops. `main` is protected against force-pushes and deletion
but does not require status checks, so the PR merges normally. Giving
Tegami a personal access token instead of `github.token` would make the
PR run checks like any other.

Two things stay deliberately manual:

- **The GitHub release is a draft.** The assets are persisted and the
  notes are written; publishing it is a click.
- **npm publishing is off** until the `NPM_PUBLISH` repository variable
  is set to `true`. It needs npm
  [trusted publishing](https://docs.npmjs.com/trusted-publishers)
  configured against `release.yml` first — no `NPM_TOKEN`, the workflow
  already has `id-token: write`. Until then the tarball is only attached
  to the draft.

### Why the version lives in two files

`npm/package.json` is the version of record, because it is the file
Tegami bumps. `app.zon` carries the same number because the Native SDK
reads it. `tools/sync-version.mjs` copies one to the other from Tegami's
`applyCliDraft` hook, CI checks they agree, and the packager refuses to
stage a package where they don't.

`npm/package.json` is also marked `"private": true`, which is what stops
Tegami from publishing it: the real package does not exist as a
directory in this repo, it is assembled into `dist/npm` out of binaries
from two runners. The packager drops the flag when it stages the public
copy.

Upgrading moves the binary, but the hooks name a copy under
`~/.ai-souls/bin` rather than the package, so they keep working — see
[Why hooks run a copy](#why-hooks-run-a-copy). Re-run `ai-souls install`
after an upgrade to bring that copy up to date.

## The catalog

| Event | Fires on | |
| --- | --- | --- |
| Session started | `SessionStart` | |
| Turn completed | `Stop` | |
| Question asked | `Notification` | |
| Tool call failed | `PostToolUseFailure` | |
| Rate limited | `StopFailure` + `rate_limit\|overloaded` | |
| API error | `StopFailure` + auth / billing / server faults | |
| PR created | `PostToolUse` + `Bash(gh pr create:*)` | |
| Commit made | `PostToolUse` + `Bash(git commit:*)` | |
| Permission denied | `PermissionDenied` | *(off)* |
| Subagent finished | `SubagentStop` | *(off)* |
| Context compacted | `PreCompact` | *(off)* |
| Session ended | `SessionEnd` | *(off)* |

The last two are the ones you cannot get any other way: Claude Code's
`StopFailure` hook fires when a turn ends on an API error, and its
matcher is the `error_type`, so "you are rate limited" and "something
is actually broken" can be two different screens.

Everything about the bar is a multiple of the headline size, so it
keeps its proportions on any display: the bar is 2.5x the type, and the
top and bottom quarter-of-a-headline of it fade out rather than ending
on a line.

Per event you can set the headline and subtitle, the colour style
(death / bonfire / victory / soul / hollow / covenant), the sound
(gong / choir / chime / ember / thud / you died, or silence),
the volume, and how long it stays up. Sounds start at 20% — these
arrive unannounced while you are concentrating, so the first one is an
accent rather than a jump scare. Changes save themselves; only arming
or disarming an event needs **Write hooks** afterwards, because that is
what changes the hook set on disk.

## About your settings.json

`ai-souls install` parses `~/.claude/settings.json` as JSON and writes
back only its own entries. Everything else — other hooks, unrelated
settings, key order — is carried through untouched, and the original is
backed up once to `settings.json.ai-souls-backup` before the first
write. Our own entries are recognised by shape (a `command` hook running
this binary with `fire <event>`), so `ai-souls uninstall` never touches
a hook it did not write. Installing twice is a no-op.

## Sounds

Gong, Choir, Chime, Ember and Thud are synthesized from scratch by
`tools/make-sounds.mjs` — a few oscillators and envelopes each, no
samples. Regenerate them with:

```bash
node tools/make-sounds.mjs
```

(ffmpeg on PATH does the mp3 encode. mp3 is the one format all three
platform audio backends decode.)

"You Died" is the exception: it is a supplied recording, not something
this repo generates, and at seven seconds it is far longer than a
screen's default 2.6 s — raise that event's duration if you want to hear
the whole thing. To add your own, drop an mp3 in `assets/sounds/` and
append it to the `Sound` enum in `src/souls.zig`. Append, never reorder:
those numbers are what `config.txt` stores.

## Files

| Path | |
| --- | --- |
| `~/.ai-souls/config.txt` | per-event settings |
| `~/.ai-souls/trigger` | the one file hooks and messages write |
| `~/.ai-souls/alive` | heartbeat, and the newest trigger acted on |
| `~/.ai-souls/bin/` | the copy installed hooks run, and its sounds |
| `~/.claude/settings.json` | where the hooks are installed |
| `~/.claude-souls/config.txt` | a pre-rename install, read once and left alone |

## Development

```bash
native dev      # run with hot reload
native test     # the test suite
native check    # validate app.zon
native build    # ReleaseFast binary
native package  # platform bundle
```

```bash
node tools/package-npm.mjs   # stage dist/npm from the last build
```

The architecture in one paragraph: `src/souls.zig` is the comptime
catalog, `src/config.zig` an allocation-free codec (so `update` can
parse and serialize without an allocator), `src/app.zig` the whole
Model/Msg/update, `src/views.zig` both windows' widget trees,
`src/hooks.zig` the JSON merge, and `src/cli.zig` the non-GUI verbs.
`update` never reads the clock, the environment, or the filesystem
directly — paths and the display size are resolved in `main` and carried
in the model, and everything else goes through the effects channel.

## Platform notes

Developed and verified on Windows 11. macOS uses the same code paths
(`NSFloatingWindowLevel`, `ignoresMouseEvents`, a clear window
background) and is expected to work. CI compiles it and runs the suite
on a macOS runner, so it is known to build and known to pass its tests —
but nobody has watched a banner appear there.

A few things worth knowing:

- **The overlay window is held open permanently**, transparent and
  empty, rather than created per screen. Native SDK reveals canvas
  windows on their first present, and on the Win32 host that reveal
  lands about 2.5 seconds late — longer than a screen's whole life.
  Paying it once at startup makes every screen instant. The cost is one
  always-present click-through window.
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
- **`ai-souls serve` hides the settings window with a raw `SW_HIDE`,**
  not with the SDK's `closeWindow`. The Win32 host's
  `close_policy = "hide"` is a `WM_CLOSE` hook, and it documents that
  runtime-initiated closes bypass it and really destroy the window —
  measured as `window_closed` followed immediately by `stop`. Hiding
  behind the host's back leaves it believing the window is on the glass,
  which costs nothing here because the permanent overlay window already
  keeps the app off the occluded path.
- **`AI_SOULS_OPAQUE=1`** runs the overlay as a solid window: the
  band stops being see-through, and in exchange it regains the Direct2D
  path and runs noticeably smoother. It is also the fallback for
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
