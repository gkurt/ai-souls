---
packages:
  ai-souls: minor
---

## The settings window is gone, and so is the flash before a banner

Every screen used to open the settings window for a blink before hiding
it — the app's one required window, put away as fast as the watchers
could catch it. Now the banner is the app's only window, so there is
nothing to flash and nothing to hide: a screen appears as the banner,
already rendered, and nothing else.

Configuration moved to the command line: `ai-souls set <event>` and
`ai-souls reset <event|all>` change everything the window did, and
`ai-souls settings` now shows the current settings instead of opening a
window. Previews are `ai-souls fire <event>` — the real thing.
