# Claude Souls

Dark Souls screens for Claude Code. A tool call fails and **YOU DIED**
bleeds across your monitor. A session starts and a bonfire is lit. The
banner is transparent, always on top, click-through, and gone in a
couple of seconds — you keep typing straight through it.

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

## How it works

One binary wearing three hats:

| Invocation | What it does |
| --- | --- |
| `claude-souls` | the app: settings window + the overlay |
| `claude-souls fire <event>` | stamps `~/.claude-souls/trigger`; this is what hooks run |
| `claude-souls install-hooks` | merges the enabled hooks into `~/.claude/settings.json` |

The running app polls the trigger file five times a second. A hook
writes one short line and exits — so nothing in Claude Code's critical
path ever waits on a window system. If the app is not running, a fire is
a no-op that the next launch quietly discards instead of replaying.

## Getting started

```bash
npm install -g @native-sdk/cli
```

```bash
native build
```

Then run the binary from `zig-out/bin/`, open the settings window, arm
the events you want, and press **Write hooks**. Screens start appearing
in every Claude Code session on the machine.

To take them all away again:

```bash
claude-souls uninstall-hooks
```

The settings window closes to a tray/menu-bar item rather than quitting —
the app has to stay alive to answer hooks. Quit from the tray menu.

## The catalog

| Event | Fires on | Default screen |
| --- | --- | --- |
| Session started | `SessionStart` | BONFIRE LIT |
| Turn completed | `Stop` | VICTORY ACHIEVED |
| Question asked | `Notification` | THE ASHEN ONE BECKONS |
| Tool call failed | `PostToolUseFailure` | YOU DIED |
| PR created | `PostToolUse` + `Bash(gh pr create:*)` | SUMMON SIGN CAST |
| Commit made | `PostToolUse` + `Bash(git commit:*)` | BONFIRE KINDLED |
| Permission denied | `PermissionDenied` | COVENANT BROKEN *(off)* |
| Subagent finished | `SubagentStop` | PHANTOM RETURNS *(off)* |
| Context compacted | `PreCompact` | HOLLOWING *(off)* |
| Session ended | `SessionEnd` | ASHEN ONE DEPARTS *(off)* |

Per event you can set the headline and subtitle, the colour style
(death / bonfire / victory / soul / hollow / covenant), the sound,
the volume, and how long it stays up. Changes save themselves; only
arming or disarming an event needs **Write hooks** afterwards, because
that is what changes the hook set on disk.

## About your settings.json

`install-hooks` parses `~/.claude/settings.json` as JSON and writes back
only its own entries. Everything else — other hooks, unrelated settings,
key order — is carried through untouched, and the original is backed up
once to `settings.json.claude-souls-backup` before the first write.
Claude Souls' own entries are recognised by shape (a `command` hook
running this binary with `fire <event>`), so `uninstall-hooks` never
touches a hook it did not write. Installing twice is a no-op.

## Sounds

The five bundled sounds are synthesized from scratch by
`tools/make-sounds.mjs` — a few oscillators and envelopes each, no
samples and nothing lifted from any game. Regenerate them with:

```bash
node tools/make-sounds.mjs
```

(ffmpeg on PATH does the mp3 encode. mp3 is the one format all three
platform audio backends decode.)

## Files

| Path | |
| --- | --- |
| `~/.claude-souls/config.txt` | per-event settings |
| `~/.claude-souls/trigger` | the one file hooks write |
| `~/.claude/settings.json` | where the hooks are installed |

## Development

```bash
native dev      # run with hot reload
native test     # the test suite
native check    # validate app.zon
native build    # ReleaseFast binary
native package  # platform bundle
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
background) and is expected to work, but has not been run.

A few things worth knowing:

- **The overlay window is held open permanently**, transparent and
  empty, rather than created per screen. Native SDK reveals canvas
  windows on their first present, and on the Win32 host that reveal
  lands about 2.5 seconds late — longer than a screen's whole life.
  Paying it once at startup makes every screen instant. The cost is one
  always-present click-through window.
- **`CLAUDE_SOULS_OPAQUE=1`** runs the overlay as a solid window. Some
  remote-desktop and compositor setups cannot present a layered window;
  a solid banner beats an invisible one.
- On Windows the overlay is a `WS_POPUP` top-level window, so it may
  show a taskbar button while it is up.
