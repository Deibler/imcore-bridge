---
"imcore-bridge": patch
---

Refuse a socket another host is still serving, instead of taking it.

`listen()` unlinked the socket path unconditionally before binding, on the
assumption that anything there was a leftover. When another host was still
serving it, that was silent theft: the new host bound a fresh inode, the old one
kept a socket bound to an inode nothing could reach any more, and the injected
side dialled whichever had bound last.

The result is a bridge that cannot be diagnosed from either end. In the case that
prompted this, three throwaway scripts from a debugging session three days
earlier were still holding the path — owning the socket keeps the process alive,
so they never exited. The daemon bound after them, was never dialled, and spent
half an hour relaunching Messages and reporting that SIP must be misconfigured.
SIP was fine.

`listen()` now probes the path first and refuses with a message naming `lsof`
when something answers. A file nobody is serving is still reclaimed, so an
unclean exit does not need manual cleanup. The failure that used to take an
afternoon now happens at startup and says what to look at.

The launch and relaunch timeout messages also stop blaming SIP for everything.
They name both causes — a dylib that did not load, and a socket held elsewhere —
because only one of them was ever printed and it was usually the wrong one.
