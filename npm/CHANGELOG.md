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
