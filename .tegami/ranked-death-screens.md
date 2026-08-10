---
packages:
  ai-souls: minor
---

## Every screen is the You Died screen

Bonfire, victory, soul, hollow and covenant were guesses at what those
banners should look like. YOU DIED in red serif is the one screen the
game is actually known for, so that is what every event ships as now —
a PR landing included. All six styles are still there to pick per event;
none of the other five becomes a default until it has been checked
against the real thing.

Screens are seven seconds by default as a result, which is how long the
You Died sting runs. Drag the duration down per event if that is more
banner than you wanted.

## The louder screen wins

Two events often land seconds apart — a commit and the PR it leads to, a
tool failing and the turn ending on it — and until now whichever got
there first took the screen and the other was simply dropped.

Events are ranked instead. A PR landing while the commit's banner is
still up replaces it. A turn ending never interrupts anything. Equal
ranks leave each other alone, so a second permission prompt does not cut
off the first one's screen. `ai-souls status` prints the ranks.

A screen you ask for by hand outranks the whole catalog, as before.
