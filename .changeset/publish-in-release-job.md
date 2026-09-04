---
"imcore-bridge": patch
---

Attach the release tarball from the release job instead of a tag-triggered
workflow. A tag pushed with the default token does not start a workflow run, so
the tag trigger never fired and v0.2.2 was tagged with nothing installable
behind it. The attach step is idempotent and repairs a release that is missing
its asset.
