---
"imcore-bridge": patch
---

Fix the publish workflow, which did not parse. Release notes are written to a
file instead of inline, and CI now parses every workflow file so an unparseable
one fails a required check rather than a startup failure on unrelated pushes.
