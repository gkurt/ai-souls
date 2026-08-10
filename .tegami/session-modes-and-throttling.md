---
packages:
  ai-souls: minor
---

## Every way a session starts is now its own event, and bursts are throttled

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
