---
"imcore-bridge": patch
---

Remove account forcing, and refuse to act on a chat that is not the one addressed.

`sendMessage:onAccount:` — the Send as Text Message mechanism, reached by
naming a `service` the chat was not bound to — re-registers the chat against
our own account inside imagent. From then on the registry object's recipient
reads as our own address and every send into it lands in the note-to-self
thread while reporting success. Every observed poisoning traces back to this
call, so it is gone: a message goes however its conversation already sends,
and naming the other service is refused with `service_mismatch` instead of
taking the poisoned route.

Beneath that, resolution now carries an invariant. Every write op asserts the
chat it resolved really is the conversation the spec addressed — identifier,
sole participant, or recipient must name the addressed handle, across e:/p:
type-prefix spellings — and refuses with `chat_mismatch` when the registry's
object is wrong, including the poison shape where the object has been fully
relabelled with our own identity (previously invisible to `chat_poisoned`,
which reads a self-identified chat as legitimate note-to-self). The typing
indicator honors the same invariant instead of lighting up the wrong thread.

Two propagation paths are closed with it: `IMBLookupHandle` no longer returns
a poisoned chat's sole participant for an address it does not match (which
handed our own IMHandle to `createChat`/`whois` and spread the damage), and
the last-resort registry scan only matches 1:1 conversations by participant,
so a DM spec can never resolve into a group. Address matching itself now
strips IMCore's e:/p: prefixes, so both spellings of one address compare
equal everywhere.
