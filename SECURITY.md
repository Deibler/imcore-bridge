# Security

## What this software requires you to give up

`imcore-bridge` loads code into Messages.app using private Apple frameworks.
Messages.app is signed with the `library-validation` flag, so this only works if
you have already:

1. Disabled System Integrity Protection (`csrutil disable` from recovery), and
2. Set the boot argument `amfi_get_out_of_my_way=0x1`.

Both are system-wide changes. Together they mean any process on the machine can
inject code into signed Apple applications, and that a meaningful part of
macOS's code-integrity model no longer applies. That is not a formality to click
past — it is the actual cost of using this library. Do not enable it on a
machine you do not control, or one holding data you would not want a local
process to reach.

## Threat model

- **The socket is the control plane.** It is created inside the Messages
  container with mode `0600`. Any process running as your user that can write to
  it can send messages as you, read your conversations, and see attachments.
  There is no additional authentication.
- **Message content leaves Messages.app.** History, attachment paths, and audio
  transcriptions are handed to whatever program holds the socket. Treat that
  program's logs and storage as containing private correspondence.
- **Attachment paths point at real files** in `~/Library/Messages/Attachments`.
  Reading them is reading the user's data.

## Stability

This library depends on private selectors that Apple may rename or remove in any
release, including a point update. Every operation is gated behind a live
`respondsToSelector:` probe so that a removed selector degrades to an
`unsupported_feature` error rather than a crash, but a macOS update can still
reduce what works without warning. The changelog records which macOS versions
each capability was verified against; nothing is claimed beyond those.

## Not crashing the host

Messages.app is a real messaging client with the user's real conversations. The
injected code:

- checks every selector before calling it,
- wraps each call in an exception handler,
- bounds every main-thread hop with a timeout instead of blocking forever, and
- refuses to run a second instance against the same socket.

If you find a way to make the injected code crash or hang Messages.app, that is
a bug worth reporting.

## Reporting a vulnerability

Open a security advisory on the repository rather than a public issue. Include
the macOS and Messages build numbers (`sw_vers`, and the app's `CFBundleVersion`)
— behaviour here is highly version-specific.
