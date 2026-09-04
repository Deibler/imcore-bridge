---
"imcore-bridge": minor
---

Catch up on what was missed, choose the service, and stop losing conversations
to a single-answer lookup.

**Reading forwards from a cursor.** `storeHistory` paged backwards only, and
required a chat. That answers "further into this conversation's past" and
cannot answer "what happened while I was not running" — you would start at the
newest message and walk towards the cursor, not knowing when to stop, across
every conversation separately, because a caller that was away does not know
which ones have news. It now takes `sinceRowID` and reads forwards, with `chat`
optional: leaving it out spans every conversation in one scan and stamps each
message with the `chatGuid` it came from. Passing both cursors is refused
rather than resolved, since a window bounded at both ends has no single
position to continue from. Asked with no cursor at all it answers with the
newest page, whose `nextSinceRowID` is where to start — so a first run begins
at now instead of replaying years of archive. Two details that only matter in
use: the cursors are taken from the page as read rather than from what came
back, so a page that folded entirely into reactions still advances; and a poll
that finds nothing hands back the cursor it was given rather than zero, so a
caller storing the reply unconditionally does not reset itself.

**A rowid on live events.** A message event carried no store rowid, so a
consumer could follow the stream but not record where it got to — which made
the catch-up above impossible to start from. IMCore calls it `messageID` and it
is the store's ROWID: verified equal on a few hundred messages across a dozen conversations,
with none missing it. It is absent until Messages has written the message,
which for one just received can be a moment after the event fires. Absent is
the safe direction — a consumer that cannot advance its cursor sees that
message twice after a restart, where a guessed rowid would move the cursor past
messages that were never delivered.

**Choosing which service carries a message.** `send` takes `service`, naming
iMessage or SMS. It routes that one message over the matching account and
deliberately leaves the conversation's own alone, since rewriting it would
change where every later message goes, including ones sent from the app by
hand. The result now names the service that carried it either way, which is the
only way to learn whether something went out as an iMessage or as a text. An
unknown name is rejected rather than falling through to the conversation's own
service and reading as though it had been honoured, and a Mac with no text
relay is refused rather than quietly sending an iMessage instead — both
verified, and neither sends anything. Forcing SMS is unverified end to end:
this machine reports `smsRelayCapable: false`, so there is no SMS account here
to send on.

**Every conversation an identifier maps to.** `resolveChat` answers with one
chat, which is fine for addressing a send and wrong for reading: the same
person can have an iMessage thread and an SMS thread, and a reply sent into the
quiet one goes somewhere nobody is looking. `resolveChats` returns the set,
most recently active first. Asking for a plain phone number on the machine this
was written on turned up two threads for one person — the ordinary one, and a
second whose GUID embedded the contact's name, last used four months earlier.

**Every conversation a handle appears in.** `chatsWith` answers with all of
them, groups included. Empty means the address has never been spoken to, which
is what makes it usable as a check before sending somewhere new rather than
only as a way to find shared groups — and it is an empty list rather than an
error, so a caller does not have to tell "no such person" apart from "the
bridge is down". Numbers match on their national digits, because the same
person is written `+15551234567` in one chat and `(555) 123-4567` in another
depending on how the conversation started; a plain string comparison answers
"never heard of them" for someone you are mid-conversation with. Fewer than ten
digits is not matched at all, since a short match would put unrelated people in
the same conversation.

**A typing indicator no longer outlives the client that set it.**
`setLocalUserIsTyping:` is a flag with no expiry: nothing clears it but an
explicit stop. A client that died mid-turn left the dots showing in a real
conversation with nobody to turn them off, and a person on the other end
waiting for a message that was never coming. The bridge now tracks what it
switched on and clears it when the host disconnects — a clean close, a crash
and a kill all reach the injected side the same way, as EOF on the socket. A
turn that stops the indicator itself leaves nothing to clear.

`hasMore` was reaching callers as `1` rather than `true`, from a C comparison
boxed as a number. The `send` documentation still described attachments going
out through Messages' scripting interface as separate messages, which stopped
being true when they moved to the injected path — they travel with the text as
one message, to any conversation, group chats included.
