---
packages:
  ai-souls: patch
---

## `install` no longer skips a binary that is the same size as the last one

It decided whether the copy your hooks run was up to date from the file's
size and path alone, so an upgrade that happened to come out the same
length was reported as installed and never actually copied. Your hooks
kept running the previous version with nothing to say so.
