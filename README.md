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

On out of the box:

| | |
| --- | --- |
| PR created | `gh pr create` succeeds |
| Commit made | `git commit` succeeds |
| Turn completed | Claude stops replying |
| Question asked | a permission prompt or a nudge |
| Tool call failed | any failed tool call |
| API error | auth, billing, a server fault |
| Rate limited | the API tells you to wait |
| Context compacted | compaction finishes |

Off, and a switch away: compaction starting, permission denied, a
subagent finishing, and the ways a session begins and ends.

Screens never stack, and the noisy ones are rate-limited — twenty
failures out of one retry loop cost you one banner, not twenty. When two
land at once the more important one wins.

`ai-souls status` prints the list as your install actually has it.

## Making it yours

Out of the box every headline is just the event's name — "Tool call
failed", "Commit made". **YOU DIED** is a much better joke when you chose
it, so write your own in the settings window. Whatever you type gets
SHOUTED on screen.

Per event: the headline and subtitle, a colour (death, bonfire, victory,
soul, hollow, covenant), a sound (gong, choir, chime, ember, thud, you
died, or silence), the volume, and how long it stays up.

Every event ships as the red **YOU DIED** screen, good news included. The
other five colours are there if you want them.

Screens run seven seconds by default, long enough for the You Died sting
to finish — drag that down if it is more banner than you wanted. Sounds
start at 20%, because these arrive while you are concentrating.

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

`install` writes back only its own entries. Other hooks, unrelated
settings and key order are carried through untouched, and the original is
backed up once to `settings.json.ai-souls-backup` before the first write.
`uninstall` never touches a hook it did not write, and installing twice
is a no-op.

Nothing stays running between banners — no daemon, no tray icon, no
polling. Each screen is its own short-lived process.

| Path | |
| --- | --- |
| `~/.ai-souls/config.txt` | your settings |
| `~/.ai-souls/bin/` | the copy the hooks run, and its sounds |
| `~/.claude/settings.json` | where the hooks live |

## Credits

Set in [EB Garamond](https://github.com/octaviopardo/EBGaramond12) (SIL
Open Font License), embedded in the binary so the screen is the same face
everywhere. The sounds are synthesized from a handful of oscillators —
no samples, nothing lifted from any game.

Built with [Vercel's Native SDK](https://github.com/vercel-labs/native):
declarative native views in Zig, no browser, no WebView, one binary.

Hacking on it? See [CONTRIBUTING.md](CONTRIBUTING.md).
