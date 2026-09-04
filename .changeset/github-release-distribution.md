---
"imcore-bridge": patch
---

Distribute through GitHub Releases instead of npm. The release tarball is what
`npm pack` produces, so `bun add <url>` and `npm install <url>` both work with
no registry account and no token on either side. A tag now triggers a publish
workflow that packs, verifies the tarball installs and runs, and attaches it.
