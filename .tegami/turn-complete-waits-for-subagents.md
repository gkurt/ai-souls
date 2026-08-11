---
packages:
  ai-souls: patch
---

## "Turn completed" no longer fires when the turn is waiting on a subagent

Claude Code ends its turn the moment it hands work to a subagent, and
ends it again when that work comes back — so half the banners you were
getting announced the opposite of what had happened. The screen now
waits for the turn that really did finish.
