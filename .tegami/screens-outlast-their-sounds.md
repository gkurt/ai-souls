---
packages:
  ai-souls: minor
---

## Screens now stay up as long as their sound

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
