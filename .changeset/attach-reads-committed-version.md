---
"imcore-bridge": patch
---

Read the released version from the commit rather than the working tree when
attaching a release asset. The changesets step versions in place while building
its pull request, so the attach step asked for a tag that did not exist yet and
reported success while attaching nothing. It now also verifies the asset is on
the release afterwards.
