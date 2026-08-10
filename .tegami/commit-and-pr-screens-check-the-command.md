---
packages:
  ai-souls: patch
---

## "Commit made" and "PR created" only fire for a commit and a PR

Both screens were turning up for ordinary Bash calls — a `grep`, an
`echo` — several times a session. The hook that runs them is narrowed to
one command, but that filter quietly matches everything for commands
Claude Code cannot read statically, so `fire` now checks the command
itself before drawing.
