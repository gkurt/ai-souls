## ai-souls@0.4.1

### A banner no longer takes focus from what you are working in (macOS)

On macOS a screen would quietly become the active app while it was up,
so keystrokes stopped going to the editor you were typing into. The
banner process now refuses the foreground outright: it draws over
everything, it stays click-through, and it never becomes the app in
front.

### Screens start at 40% volume

Twenty was quiet enough to miss. Existing installs keep whatever they
have set; `ai-souls reset all` takes the new level, and `--volume` still
overrides it per event.

### "Turn completed" no longer fires when the turn is waiting on a subagent

Claude Code ends its turn the moment it hands work to a subagent, and
ends it again when that work comes back — so half the banners you were
getting announced the opposite of what had happened. The screen now
waits for the turn that really did finish.

## ai-souls@0.4.0

### The bar has no border around it any more

macOS was drawing a window shadow behind the banner, and because the bar
is see-through the shadow showed through its own edges as a black rim on
all four sides. The soft edges now dissolve into whatever is underneath
instead of stopping at a line.

### Settings from the command line

`ai-souls set <event>` arms, disarms, and reshapes any event's screen —
on/off plus `--style`, `--sound`, `--volume`, `--duration`, `--title`,
and `--subtitle` — and `ai-souls reset <event|all>` puts things back to
their defaults. `set` prints the row back the way `status` lists it, and
tells you when arming changed so the hooks need an `install`.

### "Commit made" and "PR created" only fire for a commit and a PR

Both screens were turning up for ordinary Bash calls — a `grep`, an
`echo` — several times a session. The hook that runs them is narrowed to
one command, but that filter quietly matches everything for commands
Claude Code cannot read statically, so `fire` now checks the command
itself before drawing.

### The Death headline reads as words again

The red was so close to the band behind it that the type came out as a
warm smudge. It is a touch brighter now, and the same deep blood colour.

### `install` no longer skips a binary that is the same size as the last one

It decided whether the copy your hooks run was up to date from the file's
size and path alone, so an upgrade that happened to come out the same
length was reported as installed and never actually copied. Your hooks
kept running the previous version with nothing to say so.

### Banners land in the middle of the screen on macOS

A screen used to be drawn wherever AppKit felt like putting it, which
with a second display plugged in meant a bar somewhere off to one side
with half of it past the edge of the monitor. It now spans the display
you are working on and sits through the middle of it, the way it always
did on Windows.

### The settings window is gone, and so is the flash before a banner

Every screen used to open the settings window for a blink before hiding
it — the app's one required window, put away as fast as the watchers
could catch it. Now the banner is the app's only window, so there is
nothing to flash and nothing to hide: a screen appears as the banner,
already rendered, and nothing else.

Configuration moved to the command line: `ai-souls set <event>` and
`ai-souls reset <event|all>` change everything the window did, and
`ai-souls settings` now shows the current settings instead of opening a
window. Previews are `ai-souls fire <event>` — the real thing.

### A failed tool call no longer draws a screen

It is on the list, one switch away, and everything you have already
turned on stays on. But it is not armed for a new install: a tool call
coming back a failure is usually a step in a run that is going fine, and
the agent has moved on before you have finished reading the banner.

### The commands say something on Windows

`install`, `status`, `events`, every error — all of it printed into the
void from a terminal, because the app is a windowed program and Windows
does not hand those the console you ran them from. The install worked;
it just never told you so. Now it does, accented characters included.

### Instructions you can actually paste

Installed with `npx`? Nothing is left on PATH afterwards, so being told
to run `ai-souls settings` was a dead end. It now says `npx ai-souls
settings` when that is what you need.

## ai-souls@0.3.1

### Banners never take the keyboard

A screen used to arrive as an app: it took focus from whatever you were
typing into, put a tile in the Dock, and turned up in Cmd-Tab. Now a
banner is only a banner. Your caret stays where you left it.

One trade comes with it: the settings window opens without focus, so
click it once before you type.

### `install` works on macOS

It used to stop with "No HOME/USERPROFILE in the environment." and write
nothing, whatever your environment actually said. Your home directory was
never the problem: the app could not read its own path, and said so in the
one message it had. Both are fixed — the path resolves, and the two
failures now read differently if either ever happens again.

`install` also finishes by saying the hooks are ready.

## ai-souls@0.3.0

### Every download can be traced back to the build that made it

The binaries and the npm tarball are now signed by the workflow that
built them, so you can check that what you downloaded came from this
repository and not from someone who would like you to think so:

```bash
gh attestation verify ai-souls-v0.2.1-win32-x64.exe --repo gkurt/ai-souls
```

The npm package carries its own provenance too, published over OIDC with
no token anywhere in the pipeline.

### The release that actually reaches npm

0.2.0 was tagged and built — both binaries, both slots — and then fell
over on the last step. `npm publish tarball/*.tgz` reads a bare
`dir/file.tgz` as a GitHub `owner/repo` shorthand, so npm went looking
for a git repository named after the tarball instead of publishing it.

Nothing was wrong with 0.2.0 itself; it just never left the building.
Everything in its notes below ships here.

### Every screen is the You Died screen

Bonfire, victory, soul, hollow and covenant were guesses at what those
banners should look like. YOU DIED in red serif is the one screen the
game is actually known for, so that is what every event ships as now —
a PR landing included. All six styles are still there to pick per event;
none of the other five becomes a default until it has been checked
against the real thing.

Screens are seven seconds by default as a result, which is how long the
You Died sting runs. Drag the duration down per event if that is more
banner than you wanted.

### The louder screen wins

Two events often land seconds apart — a commit and the PR it leads to, a
tool failing and the turn ending on it — and until now whichever got
there first took the screen and the other was simply dropped.

Events are ranked instead. A PR landing while the commit's banner is
still up replaces it. A turn ending never interrupts anything. Equal
ranks leave each other alone, so a second permission prompt does not cut
off the first one's screen. `ai-souls status` prints the ranks.

A screen you ask for by hand outranks the whole catalog, as before.

## ai-souls@0.2.0

### macOS is a supported platform

The package now carries a universal macOS binary alongside the Windows
one, so Apple Silicon and Intel Macs both install a working `ai-souls`
instead of the "no binary for darwin-arm64" message.

### A screen is a process — nothing stays resident

AI Souls no longer leaves anything running between banners. There is no
background app, no tray icon, and no polling: a hook's `ai-souls fire`
draws its own screen and exits with it.

The app that used to sit in the tray cost about 3.5% of a CPU core
continuously, and it also meant that after a reboot nothing was
listening — hooks fired into a void until you happened to start the app
by hand. Both are gone.

A banner now appears about 295 ms after the hook runs, from a completely
cold start.

`ai-souls serve` is removed; it has nothing left to do. `ai-souls
settings` still opens the settings window, and closing that window now
ends the process rather than hiding it in the tray.

### `install` says where the settings are

`npx ai-souls install` is now the recommended way in, and it leaves
nothing on your PATH — so `install` points at the tray icon rather than
letting you find it yourself.

### Screens now stay up as long as their sound

Every screen was 2.6 seconds regardless of what it played, and the
overlay stops the audio when it ends — so the You Died sting, which runs
7.2 seconds, was chopped off less than halfway through. Every death
screen has been cutting itself off.

A screen is now sized to its own sound by default: 7.2 seconds for You
Died, 3.3 for the choir, 3.7 for the gong. A short sound does not
shorten the screen — 2.6 seconds is still the floor, because that is how
long it takes to read one.

Your own durations are untouched, and picking a longer sound in the
settings window will not move a slider you have set yourself — it says
so under the slider instead, and **Reset to default** sizes it to fit.

Tool call failed is throttled to one screen every 30 seconds rather than
15, now that the screen it draws is seven seconds long.

### Every way a session starts is now its own event, and bursts are throttled

`SessionStart` fires for five different reasons — a fresh start, a
resume, a `/clear`, a fork, and the end of a compaction — and AI Souls
used to treat them as one event that was armed by default. Opening a
terminal got you the same screen as anything else.

They are five separate rows now, and only **Context compacted** is on
out of the box. That is the one worth interrupting someone for:
compaction happens without asking, takes a while, and the session that
comes back has forgotten things. The other four you already know about,
because you caused them.

Screens are also throttled. No screen draws over one that is still up,
and the events that arrive in bursts get a window of their own on top of
that — a tool failure at most once every 15 seconds, a rate limit once a
minute. An agent that has got something wrong tends to get it wrong
twenty times in a row, and the twentieth screen says nothing the first
one did. The windows are per event, so a storm of failures never
swallows the API error that follows it, and a screen you ask for by hand
is never held back. `ai-souls status` prints what applies to what.

Every error now looks and sounds like one: **Rate limited** and **API
error** have joined **Tool call failed** as red You Died screens.
