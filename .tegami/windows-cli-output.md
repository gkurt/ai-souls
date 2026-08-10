---
packages:
  ai-souls: patch
---

## The commands say something on Windows

`install`, `status`, `events`, every error — all of it printed into the
void from a terminal, because the app is a windowed program and Windows
does not hand those the console you ran them from. The install worked;
it just never told you so. Now it does, accented characters included.

## Instructions you can actually paste

Installed with `npx`? Nothing is left on PATH afterwards, so being told
to run `ai-souls settings` was a dead end. It now says `npx ai-souls
settings` when that is what you need.
