---
"imcore-bridge": patch
---

Only force an account when the conversation is known to be somewhere else.

Naming a service routes one message over that service's account, which is what
the composer does for Send as Text Message. The check for whether that was
needed asked whether the chat was already on the named service, and a chat whose
account is not bound yet — freshly resolved, or Messages only just relaunched —
answers with no service at all. That read as "on a different service", so an
ordinary reply went out with `sendMessage:onAccount:` instead of into the chat,
and arrived at the sender's own address rather than the recipient's. It looked
like a successful send from every angle except the recipient's.

Unknown now counts as "not somewhere else". Forcing an account is the
destructive branch, so it is taken only on positive evidence that the
conversation is on another service.
