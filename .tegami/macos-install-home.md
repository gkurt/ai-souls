---
packages:
  ai-souls: patch
---

## `install` works on macOS

It used to stop with "No HOME/USERPROFILE in the environment." and write
nothing, whatever your environment actually said. Your home directory was
never the problem: the app could not read its own path, and said so in the
one message it had. Both are fixed — the path resolves, and the two
failures now read differently if either ever happens again.

`install` also finishes by saying the hooks are ready.
