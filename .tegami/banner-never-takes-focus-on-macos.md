---
packages:
  ai-souls: patch
---

## A banner no longer takes focus from what you are working in (macOS)

On macOS a screen would quietly become the active app while it was up,
so keystrokes stopped going to the editor you were typing into. The
banner process now refuses the foreground outright: it draws over
everything, it stays click-through, and it never becomes the app in
front.
