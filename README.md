# AI Souls

Dark Souls screens for your coding agent. A tool call fails and a banner
bleeds across your monitor. A commit lands and another one lights up.

It is transparent, always on top, click-through, and gone in a couple of
seconds. You keep typing straight through it.

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

> **Not on npm yet.** The first release is on its way. Until then, grab a
> binary from the
> [latest CI run](https://github.com/gkurt/ai-souls/actions/workflows/ci.yml).

```bash
npx ai-souls install
```

That is it. Screens start appearing in every Claude Code session on the
machine, and they keep working after npm collects its cache — `install`
tucks a copy away in `~/.ai-souls` and points the hooks at that.

See one right now:

```bash
npx ai-souls "YOU DIED"
```

Change what they say:

```bash
npx ai-souls settings
```

Claude Code is the only agent wired up so far.

## What fires when

Listed loudest first — see below.

| | Fires on | |
| --- | --- | --- |
| PR created | `gh pr create` succeeds | |
| Question asked | a permission prompt or a nudge | max 1 / 10s |
| API error | auth, billing, a server fault | max 1 / 30s |
| Rate limited | the API tells you to wait | max 1 / 60s |
| Commit made | `git commit` succeeds | |
| Tool call failed | any failed tool call | max 1 / 30s |
| Context compacted | compaction finishes | |
| Turn completed | Claude stops replying | |
| Permission denied | a tool call is refused | *(off)*, max 1 / 10s |
| Subagent finished | | *(off)*, max 1 / 10s |
| Compacting context | compaction begins | *(off)* |
| Session started / resumed / cleared / forked | | *(off)* |
| Session ended | | *(off)* |

Of the five ways a session can start, only **Context compacted** is on:
compaction happens without asking, takes a while, and the session that
comes back has forgotten things. The other four you already know about,
because you caused them.

Screens never stack. Two of these often land seconds apart — a commit and
the PR it leads to, a tool failing and the turn ending on it — so they
are ranked, and the louder one wins. A PR landing while the commit's
banner is still up replaces it; a turn ending while anything else is on
screen waits for a quieter moment that never comes. Same rank, no
interruption. (Replacing a banner already on screen is Windows-only —
on macOS the quieter event is dropped instead.)

On top of that the noisy events get a cooldown, because an agent that has
got something wrong tends to get it wrong twenty times in a row and the
twentieth banner says nothing the first one did.

A screen you ask for by hand outranks all of it and is never held back.

`ai-souls status` prints the list as your install actually has it, ranks
and cooldowns included.

## Making it yours

Out of the box every headline is just the event's name — "Tool call
failed", "Commit made". **YOU DIED** is a much better joke when you chose
it, so write your own in the settings window. Whatever you type gets
SHOUTED on screen.

Per event: the headline and subtitle, a colour (death, bonfire, victory,
soul, hollow, covenant), a sound (gong, choir, chime, ember, thud, you
died, or silence), the volume, and how long it stays up.

Everything ships as the red **YOU DIED** screen, whether or not the event
is bad news — that is the one screen the game is actually known for, and
the other five are our guesses at what a bonfire or a covenant banner
should look like. They are all there to pick; none of them is a default
until it has been checked against the real thing. Pull the whole catalog
in five directions if you like.

A screen lasts as long as its own sound, so nothing gets cut off
mid-ring. That makes the default seven seconds, which is how long the
You Died sting runs — drag the duration down per event if that is more
banner than you wanted. Sounds start at 20%, because these arrive while
you are concentrating and the first one should be an accent, not a jump
scare.

Changes save themselves. Only arming or disarming an event needs **Write
hooks** afterwards, since that is what changes the hooks on disk.

## The command

```
ai-souls <message>       put a headline on screen
ai-souls settings        open the settings window
ai-souls install         write the enabled hooks into Claude Code
ai-souls uninstall       remove every AI Souls hook
ai-souls status          show paths and per-event settings
ai-souls fire <event>    show one event's screen (this is what hooks run)
```

Anything that is not a verb is a headline, so quoting is optional:

```bash
ai-souls PRAISE THE SUN --style victory --sound choir
```

| Option | |
| --- | --- |
| `--style <name>` | death, bonfire, victory, soul, hollow, covenant |
| `--sound <name>` | silent, gong, choir, chime, ember, thud, you-died |
| `--volume <0-100>` | |
| `--duration <ms>` | 600 to 10000 |
| `--subtitle <text>` | |
| `--` | everything after this is the message |

Prefix any of them with `npx`, or `npm install -g ai-souls` if you would
rather have the command itself — the hooks do not need it, but it saves
npm's resolution cost every time you type one.

## Your settings.json is safe

`install` parses `~/.claude/settings.json` and writes back only its own
entries. Other hooks, unrelated settings and key order are carried
through untouched, and the original is backed up once to
`settings.json.ai-souls-backup` before the first write.

AI Souls recognises its own entries by shape, so `uninstall` never
touches a hook it did not write. Installing twice is a no-op.

Nothing stays running between banners. No daemon, no tray icon, no
polling — each screen is its own short-lived process, and a banner
appears about 300 ms after the hook fires.

| Path | |
| --- | --- |
| `~/.ai-souls/config.txt` | your settings |
| `~/.ai-souls/bin/` | the copy the hooks run, and its sounds |
| `~/.claude/settings.json` | where the hooks live |

Every binary and tarball is signed by the workflow that built it, so you
can check a download came from this repo and not from someone else:

```bash
gh attestation verify ai-souls-v0.2.1-win32-x64.exe --repo gkurt/ai-souls
```

## Credits

Set in [EB Garamond](https://github.com/octaviopardo/EBGaramond12) (SIL
Open Font License), embedded in the binary so the screen is the same face
everywhere. The sounds are synthesized from a handful of oscillators —
no samples, nothing lifted from any game.

Built with [Vercel's Native SDK](https://github.com/vercel-labs/native):
declarative native views in Zig, no browser, no WebView, one binary.

Hacking on it? See [CONTRIBUTING.md](CONTRIBUTING.md).
