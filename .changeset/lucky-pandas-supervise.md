---
"imcore-bridge": minor
---

Keep the bridge up without being asked: `supervise()`.

`launch()` is one shot. It owns a socket, injects, and hands back a connected
bridge — which is right for a script and not enough for a process that has to
stay reachable for days. The client already survives Messages restarting on its
own, because the socket outlives the app and the injected side re-dials with
backoff. Two things it could not do alone are what `supervise()` adds.

**Messages is brought back when nothing else will.** It crashed, the user quit
it, or it is running without the dylib and so will never dial. Relaunches are
serialised and backed off, so an app that refuses to start is retried at a
widening interval instead of in a loop, and concurrent callers collapse into one
restart rather than several.

**A bridge that stops answering is noticed.** This is the failure that prompted
it: the socket stays open and `isConnected` keeps reporting true while the
injected side has stopped serving RPCs. Every call then burns its full timeout
before failing, and because the connection never dropped there is nothing to
react to. Asking periodically, with a deadline much shorter than the one real
sends need, is what separates a quiet bridge from a wedged one — and relaunching
Messages is the only thing that clears it. `relaunch()` is public for the same
reason: a send that just timed out is better evidence than the next probe, and
the host should not have to wait for one.

An already-injected Messages is adopted rather than restarted, so a host that
restarts often stops closing the user's messaging client every time it comes up.
`stop()` leaves Messages running — the host exiting is not a reason to quit it.

The bridge handed back is stable across relaunches, so long-lived consumers like
`events()` keep working and never resubscribe.
