---
packages:
  ai-souls: patch
---

## Every download can be traced back to the build that made it

The binaries and the npm tarball are now signed by the workflow that
built them, so you can check that what you downloaded came from this
repository and not from someone who would like you to think so:

```bash
gh attestation verify ai-souls-v0.2.1-win32-x64.exe --repo gkurt/ai-souls
```

The npm package carries its own provenance too, published over OIDC with
no token anywhere in the pipeline.
