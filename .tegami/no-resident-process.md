---
packages:
  ai-souls: minor
---

# A screen is a process — nothing stays resident

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
