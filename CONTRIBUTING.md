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
the banner's widget tree, `src/hooks.zig` the JSON merge,
`src/hook_input.zig` the payload a hook is handed on stdin, and
`src/cli.zig` every verb but the banner itself.

`update` never reads the clock, the environment, or the filesystem
directly. Paths and the display size are resolved in `main` and carried
in the model; everything else goes through the effects channel. That is
what lets the suite drive the whole app without a window.

**A screen is a process.** Nothing stays resident.

| Invocation | What it does |
| --- | --- |
| `ai-souls fire <event>` | resolves the event, draws its banner, exits — this is what hooks run |
| `ai-souls "..."` | the same, for a headline you typed |
| `ai-souls set <event> …` | edits one row of `~/.ai-souls/config.txt` and exits |
| `ai-souls install` | merges the enabled hooks into `~/.claude/settings.json` |

A hook's `fire` reads the config, and if that event is off it exits
before touching a window system at all. If it is on, the process becomes
the banner, holds it, and quits with it. Measured on Windows from a
completely dead start, four runs: visible at 269–458 ms, median 295 ms.

### Why "Commit made" checks the command twice

"PR created" and "Commit made" both subscribe to `PostToolUse` on `Bash`,
so both need narrowing to one call out of every command a session runs.
The hook entry carries Claude Code's `if` rule for that —
`"if": "Bash(git commit:*)"` — and it is honoured, but its Bash matcher
**fails open**: when the shell text is something the static analyser will
not model, the rule matches everything rather than nothing. `echo
{alpha,beta}` is enough to do it; so are a heredoc with an unquoted
delimiter, a redirect it cannot account for, and a parse it had to
abandon. The result was both screens firing for unrelated Bash calls,
several times a session.

So the rule is an optimisation — it saves spawning us for the commands
Claude Code does recognise — and the decision belongs to `fire`. Claude
Code writes the hook payload to our stdin, `src/hook_input.zig` reads
`tool_input.command` out of it, and a row that names a command
(`Event.requiredCommand`, read back off the rule so the two cannot
drift) draws only if that command really runs it. The question is the
same one the permission rule asks — the command has to begin a command
and be the whole of the words it spans, so `cd repo && git commit -m x`
counts and `grep -rn 'git commit'` does not.

Only those rows read stdin, and a payload we cannot make sense of draws:
the gate is there to catch a hook that fired for the wrong Bash call, not
to invent a new way to lose one. `ai-souls fire commit_made` typed into a
terminal still shows you the screen — stdin is a tty, so there is no
payload to check, and blocking a banner on someone typing would be worse
than a banner too many.

This replaced a resident app that held an always-open transparent window
and polled a trigger file five times a second, on the belief that
revealing a canvas window cost ~2.5 s and had to be paid once at
startup. The number was wrong (see [Platform notes](#platform-notes)).
The resident process cost ~3.5% of a core continuously, and meant that
after a reboot nothing was listening until you started the app by hand.

## Which screen wins

Two full-screen banners at once is not an option, and with nothing
resident there is nowhere to keep "one is already up" except a file.
`src/throttle.zig` is that file (`~/.ai-souls/fired.txt`) and the rules
over it. `fire` reads it before deciding and writes it after deciding
yes — one small read and one small write, on the only path that was
going to open a window anyway. A screen it decides against costs the
read and exits `handled_ok`: a hook reporting failure over a suppressed
decoration would be a bug.

Three rules, in order:

1. **The floor.** Nothing draws over a banner that is still up. The
   record carries the incumbent's own `duration_ms`, so this is exact
   rather than a guess.
2. **The rank.** `Event.priority` is the exception to the floor. A
   screen that strictly outranks the incumbent takes the glass; the
   incumbent's banner comes down. Ties do not displace — the second
   permission prompt of a run leaves the first one's screen alone.
3. **The window.** `Event.throttle_ms`, per event and only against
   itself. Outranking your way past the floor does not exempt you from
   this.

Ranks are comptime, not configurable, and the numbers mean nothing
except in relation to each other. `ai-souls status` prints them.

`ai-souls "..."` is exempt from all three at `souls.by_hand_priority` —
it is an instruction, not a notification. It still records itself, so
nothing lands on top of it either.

The record is racy on purpose. Two hooks in the same instant both read
the same stamp and both decide yes. Locking a file to arbitrate a
decoration costs more than the double screen it prevents, and the hook
events that actually burst are serialized by Claude Code anyway.

### Taking the incumbent down

The decision is made in `cli.zig`; acting on it is `main`'s job, next to
the window it clears the way for. `overlay_style.dismissOthers` walks
top-level windows carrying the banner's private title, skips this
process's own, hides each match and terminates its process with exit
code 0 — that process is some hook's `ai-souls fire`, still being waited
on by Claude Code, and being superseded is not a failure.

It terminates rather than posting `WM_CLOSE`, for two reasons. The pid
comes from a live window with our own title, so there is no pid-reuse
hazard to guard against. And a close the host chose to ignore would
leave the loser's sound playing underneath the winner's.

This is why there are **two** banner window titles. The shell band is
"AI Souls Screen"; the opaque-mode fallback window (see
[Platform notes](#platform-notes)) is "AI Souls Overlay", so the
watchers inside one process can tell the two apart. A dismisser hunts
both titles, so a banner comes down whichever mode drew it.

`overlay_style.can_dismiss` gates the whole thing, and it is Win32-only:
the mechanism leans entirely on `FindWindowExW` naming a window in
another process, and AppKit has no equivalent outside Accessibility.
Where it is false the floor is absolute and rank never fires, so a
screen is missed rather than drawn over another one — which is the right
way round to fail. The throttle tests for preemption skip themselves
there.

Closing the gap means finding another process's banner window without
`FindWindowExW`. The likeliest route is recording the screen's pid in
`fired.txt` and sending it a signal, which the throttle already has the
file for.

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

### Provenance

Three artifacts get signed, and they are signed in two different ways
for two different audiences.

`actions/attest-build-provenance` runs in the `build` job on each
binary and in `package` on the tarball, so anything downloaded from a
GitHub release can be checked against the workflow and commit that
produced it:

```bash
gh attestation verify ai-souls-v0.2.1-win32-x64.exe --repo gkurt/ai-souls
```

It signs the binary where it is built, which for macOS is deliberately
*after* `lipo` — the fused universal binary is what people download and
neither slice is. Attestation is by digest, so the artifact round trip
and the rename into `ai-souls-v1.2.3-<slot>.exe` do not disturb it. Both
jobs need `id-token: write` and `attestations: write`.

npm handles its own: trusted publishing attaches provenance without
being asked, which is why there is no `--provenance` flag on the publish
step. It needs a public `repository` field in `package.json` matching
where it is published from — that field is load-bearing, not decoration.

One open question the pipeline answers for itself. npm's docs do not say
whether automatic provenance survives publishing a *pre-built tarball*
rather than a directory, and that is what we do. The publish job checks
the registry afterwards and emits a warning if the attestation is
missing, rather than failing a release that already reached npm. If that
warning ever shows up, the fix is to pack and publish in the same job.

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
| **`version.yml`** — push to `main` | `tegami ci` turns pending changelogs into a **`chore: release v<version>`** PR: bumped `npm/package.json` + `app.zon`, and `CHANGELOG.md`. Merging it pushes a `v<version>` tag and starts the release. |
| **`release.yml`** — dispatched by `version.yml`, or a `v*` tag pushed by hand | Builds both slots, fuses the macOS one, packs the tarball, drafts a GitHub release with the changelog as its notes, and publishes to npm. |

So the decision a human makes is **merging the release PR**. Its title
carries the version it is about to cut, rather than Tegami's flat
"Version Packages", so `main`'s history reads as a list of releases.

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

The same rule is why the release PR gets no CI of its own.
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
`ignoresMouseEvents`, a clear window background). CI compiles it and runs
the suite on a macOS runner, so it builds and passes there. The one
deliberate behavioural difference is preemption, which is Win32-only —
see [Which screen wins](#which-screen-wins).

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
- **The band is the shell window the host creates from `app.zon`,**
  before any app code runs, with everything but its size fixed at
  create — the manifest is comptime, so no process can vary those flags.
  A canvas window is created ordered-out and revealed only after its
  first frame presents, which is exactly the reveal a banner wants:
  nothing else ever flashes on screen. The scene built in `main`
  re-declares the window with the real display's size (the one thing the
  manifest cannot know), and `overlay_style` does the placing.
- **`AI_SOULS_OPAQUE=1`** runs the banner as a solid window: the band
  stops being see-through, and in exchange it regains the Direct2D path
  and runs noticeably smoother. It is also the fallback for
  remote-desktop and compositor setups that cannot present a layered
  window at all, where a solid banner beats an invisible one. Because
  the shell band's transparency is fixed in the manifest, this mode
  draws in a second, opaque window declared from the model
  (`main.declaredWindows`) while the shell band paints nothing.
- **The overlay window's style is fixed from Win32 directly**
  (`src/overlay_style.zig`), because the SDK's `WindowDescriptor` cannot
  express it. It is a borderless top-level window — `WS_POPUP` with no
  owner — which the shell would otherwise give a taskbar button and an
  Alt+Tab entry, so `WS_EX_TOOLWINDOW` and `WS_EX_NOACTIVATE` are set on
  it.
- **No host applies the descriptor's `x`/`y`,** so the bar is moved after
  the window exists or it is not where it was asked to be. The Win32 host
  passes `CW_USEDEFAULT` to `CreateWindowExW`, which parks it across the
  top of the screen. The AppKit host takes the size and leaves the origin
  to AppKit, which is easy to miss on one display and obvious on two:
  measured with a 1512x982 primary and a 1920x1080 beside it, a band
  asked for at (0, 387) was created at (1920, 149) — on the other
  display, hanging off the right of it. `overlay_style` does the moving
  on both, `SetWindowPos` in the physical pixels Win32 speaks and
  `setFrame:display:` in AppKit's global points, whose origin is the
  primary display's BOTTOM-left — which is why `main.bandFrame` hands
  macOS a flipped `y` rather than the descriptor's own.
- **Which display the banner uses is decided in `screen.zig`,** once,
  before the window exists, because `update` may not ask the OS anything.
  On macOS it is the display the pointer is on: a laptop with an external
  monitor puts the primary under your hands maybe half the time, and a
  banner nobody is looking at may as well not have drawn. Win32 stays on
  the primary, which is the display `centre` measures anyway. The size
  that comes back is also what the type and the band are sized against,
  so both have to be the same display or the bar spans the wrong width.
- **The banner window's shadow is turned off.** AppKit shadows every
  window, and a translucent one shows that shadow through its own
  pixels: a black rim around all four sides, worst exactly where the
  soft edge is trying to dissolve into the desktop, which reads as a
  border drawn around the bar. `setHasShadow:NO` goes on with the frame.
- **No window this app declares may activate.** `activate_on_show =
  false` on every window — and on the shell band it has to be in
  `app.zon`, because the host creates that one before any app code
  runs. A window's reveal activating the app is how a hook used to take
  the keyboard from whatever you were typing into.
- **A banner process also leaves the Dock on macOS.** The host asks for
  `NSApplicationActivationPolicyRegular`, which is a Dock tile and a
  Cmd-Tab entry either way; a banner asks for `Accessory` instead,
  through `objc_msgSend` on the main queue like the rest of the AppKit
  errands in `overlay_style` — there is no Objective-C in this project
  and no need for any. `Accessory`, not `Prohibited`: the latter is
  unable to create windows at all, and the banner is a window.
- **Windows prints nothing unless it goes looking for the terminal**
  (`src/console.zig`). The release binary is GUI-subsystem — a
  console-subsystem one flashes a terminal window behind every banner —
  and Windows does not attach a GUI process to the console that launched
  it, so `GetStdHandle` answers with nothing usable and every line the
  CLI writes is discarded. Measured as an empty console screen buffer
  from a `cmd /k ai-souls install` that wrote `settings.json` perfectly
  well. So a redirected handle is kept as-is (a pipe is a parent reading
  us, a file is `>`), and anything else attaches to the parent's console
  and writes to `CONOUT$` — with the console's code page set to UTF-8 for
  the duration, because the default 437/850 turns every em dash in these
  messages into nonsense, and put back as the verbs return.
- **A message that says "type this next" spells the command with
  `invocation`,** not `command_name`. `npx ai-souls install` leaves
  nothing on PATH — the package is unpacked into `_npx/<hash>` and npm
  collects it later — so that reader needs `npx ai-souls set …`. It is
  read off our own path, not npm's environment variables: those say a
  package manager ran us, not that the binary is somewhere temporary.
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
