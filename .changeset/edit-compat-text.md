---
"imcore-bridge": patch
---

Edits go out again on macOS 26. The daemon declares the edit's `backwardCompatabilityText:` argument as `NSAttributedString` and dropped every edit carrying an `NSString` while decoding it, with nothing reported back to the app, so `edit` returned normally and the message never changed. The bridge now reads the declared class from `IMDaemonChatSendMessageProtocol` and passes what the daemon will accept.
