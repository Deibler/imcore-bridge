---
"imcore-bridge": minor
---

Stop guessing whether an operation happened: ask first, retry safely, and check
afterwards.

**Group membership changes are asked about before they are made.** Removing
someone from a group of three would leave two, and IMCore declines — by doing
nothing and saying nothing, which reads as a change that took effect. The docs
here recorded that as a known partial and left callers to detect it by reading
the group back. IMCore knows the answer in advance: `canAddParticipants:` and
`canRemoveParticipants:` are what the app asks before it enables the menu item.
Both membership calls now ask, and refuse with a reason instead of reporting a
success that did nothing.

The check is also exposed on its own as `group.canAdd` / `group.canRemove`,
because it is read-only and therefore the one thing in this area that can be
verified without a real conversation changing to tell you. Which is how it was
verified: a three-person group answers no to a removal, a nine-person group
answers yes, and a 1:1 answers no to an addition. Twenty-eight of the sixty-two
groups on the machine this was written on have three people in them, so the
silent case was the common one.

**A send can now be repeated safely, and its fate looked up afterwards.** A send
that reaches Messages and then loses its reply — a timeout, a dropped socket, a
client that died in between — left the caller unable to tell whether it went
out. Retrying sent it twice; not retrying dropped it; neither was fixable
afterwards, because nothing in the message store tied an attempt to the caller's
intent. `send` now takes an `idempotencyKey` of the caller's choosing: the same
key inside the window returns the original GUID marked `duplicate` and sends
nothing. Verified by sending the same key twice and finding one bubble in the
store. The record lives in the injected process and is dropped when Messages
restarts, deliberately — it covers a retry cycle, not a decision to send the
same thing again hours later.

`sendStatus` answers the other half, by GUID: `unknown`, `pending`, `sent`,
`delivered`, `read` or `failed`. `unknown` is a real answer rather than a
failure, since a message not yet written to the store and one that was never
sent are indistinguishable from here — so it is reported as what it is instead
of being guessed between.

**A sticker can be stuck onto an existing bubble**, the way peel-and-stick does,
rather than only sent on its own. A stuck sticker turns out not to be a message
with a picture in it: it is an _associated_ message, addressed the way a tapback
is — `p:<part>/<guid>` plus the range it covers — carrying type 1000 and a
sticker transfer. That shape is in no header; it came from reading the nine
already in this machine's store. The one factory that takes both a transfer list
and the association triple is the long initialiser, since every convenience
method drops one or the other — the same trap the ordinary send path documents.
Verified by sending one and reading it back with the right type, target and
sticker flag.

**Deleting a conversation** is now distinct from emptying one. `deleteHistory`
leaves the conversation in the list with nothing in it, which is not what a
person means by deleting a chat; `deleteChat` removes the thread itself via
`-[IMChat remove]`. Both are local — the other party keeps their copy either
way. Shipped unverified: there is no throwaway conversation on this machine, and
unlike emptying, this one takes the thread.

**Sharing your Name & Photo** is possible where before only reading other
people's cards was. It is deliberately an explicit call and never a side effect
of anything else, because it discloses the name and picture of whoever is
running this. Shipped unverified for the same reason: testing it means sending a
real person your profile.
