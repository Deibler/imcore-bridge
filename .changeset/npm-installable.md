---
"imcore-bridge": minor
---

Make the package installable from npm. The dylib is now compiled at install
time by a best effort `postinstall` that never fails the install, and a new
`imcore-bridge build-native` command builds it later for anyone who installed
with scripts disabled or without the Xcode Command Line Tools. The missing
dylib error now names a command a consumer can actually run.
