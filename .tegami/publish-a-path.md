---
packages:
  ai-souls: patch
---

## The release that actually reaches npm

0.2.0 was tagged and built — both binaries, both slots — and then fell
over on the last step. `npm publish tarball/*.tgz` reads a bare
`dir/file.tgz` as a GitHub `owner/repo` shorthand, so npm went looking
for a git repository named after the tarball instead of publishing it.

Nothing was wrong with 0.2.0 itself; it just never left the building.
Everything in its notes below ships here.
